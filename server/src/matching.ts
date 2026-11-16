import type { PoolClient } from 'pg';
import type { AppContext } from './http/context.js';
import { withTransaction } from './db/pool.js';
import { conflict, notFound, serviceUnavailable } from './http/errors.js';
import { postJournalOnce, setTradeStatus, mapTrade, ledgerAccountId, type TradeRow, type TradeView } from './trades.js';
import {
  refundTrade,
  startDisbursement,
  type DisbursementResult,
} from './payments.js';

export interface MatchRow {
  id: string;
  buy_trade_id: string;
  sell_trade_id: string | null;
  liquidity_order_id: string | null;
  buy_amount_minor: string;
  sell_amount_minor: string;
  buy_currency: string;
  sell_currency: string;
  status: 'proposed' | 'locked' | 'released' | 'cancelled' | 'failed';
  match_rate: string | null;
  matched_at: Date | null;
  released_at: Date | null;
}

export interface MatchView {
  id: string;
  status: MatchRow['status'];
  rate: number | null;
  buyCurrency: string;
  sellCurrency: string;
  buyAmountMinor: number;
  sellAmountMinor: number;
  liquidity: boolean;
  matchedAt: string | null;
  releasedAt: string | null;
}

export interface LiquidityOrderRow {
  id: string;
  provider_id: string;
  provide_currency: string;
  receive_currency: string;
  capacity_minor: string;
  remaining_minor: string;
  min_amount_minor: string;
  max_amount_minor: string;
  rate: string;
  status: 'active' | 'depleted' | 'expired' | 'cancelled';
  expires_at: Date;
}

export interface CorridorRow {
  send_currency: string;
  receive_currency: string;
  enabled: boolean;
  exposure_cap_minor: string | null;
  min_amount_minor: string | null;
  max_amount_minor: string | null;
  match_deadline_seconds: number;
  spread_bps: number;
}

const MATCH_COLUMNS = `id, buy_trade_id, sell_trade_id, liquidity_order_id,
  buy_amount_minor, sell_amount_minor, buy_currency, sell_currency, status,
  match_rate, matched_at, released_at`;

export function mapMatch(row: MatchRow): MatchView {
  return {
    id: row.id,
    status: row.status,
    rate: row.match_rate === null ? null : Number(row.match_rate),
    buyCurrency: row.buy_currency,
    sellCurrency: row.sell_currency,
    buyAmountMinor: Number(row.buy_amount_minor),
    sellAmountMinor: Number(row.sell_amount_minor),
    liquidity: row.liquidity_order_id !== null,
    matchedAt: row.matched_at === null ? null : new Date(row.matched_at).toISOString(),
    releasedAt: row.released_at === null ? null : new Date(row.released_at).toISOString(),
  };
}

async function loadCorridor(
  client: PoolClient,
  sendCurrency: string,
  receiveCurrency: string,
  forUpdate = false,
): Promise<CorridorRow | null> {
  const result = await client.query<CorridorRow>(
    `SELECT send_currency, receive_currency, enabled, exposure_cap_minor,
            min_amount_minor, max_amount_minor, match_deadline_seconds, spread_bps
     FROM p2p_corridors
     WHERE send_currency = $1 AND receive_currency = $2${forUpdate ? ' FOR UPDATE' : ''}`,
    [sendCurrency, receiveCurrency],
  );
  return result.rows[0] ?? null;
}

async function openExposure(client: PoolClient, currency: string): Promise<bigint> {
  const result = await client.query<{ total: string }>(
    `SELECT COALESCE(sum(send_amount_minor), 0)::text AS total
     FROM trades
     WHERE send_currency = $1
       AND status IN ('escrowed', 'matching', 'matched', 'disbursing')`,
    [currency],
  );
  return BigInt(result.rows[0]?.total ?? '0');
}

async function findLiquidityOrder(
  client: PoolClient,
  input: {
    provideCurrency: string;
    receiveCurrency: string;
    provideAmountMinor: bigint;
  },
): Promise<LiquidityOrderRow | null> {
  const result = await client.query<LiquidityOrderRow>(
    `SELECT o.id, o.provider_id, o.provide_currency, o.receive_currency,
            o.capacity_minor, o.remaining_minor, o.min_amount_minor,
            o.max_amount_minor, o.rate, o.status, o.expires_at
     FROM liquidity_orders o
     JOIN liquidity_providers p ON p.id = o.provider_id
     WHERE o.status = 'active'
       AND p.status = 'active'
       AND o.prefunded_at IS NOT NULL
       AND o.provide_currency = $1
       AND o.receive_currency = $2
       AND o.remaining_minor >= $3
       AND o.min_amount_minor <= $3
       AND o.max_amount_minor >= $3
       AND o.expires_at > now()
     ORDER BY o.rate ASC, o.expires_at ASC, o.created_at ASC
     FOR UPDATE OF o SKIP LOCKED
     LIMIT 1`,
    [input.provideCurrency, input.receiveCurrency, input.provideAmountMinor.toString()],
  );
  return result.rows[0] ?? null;
}

function receiveCost(provideAmountMinor: bigint, rate: string): bigint {
  const value = Number(provideAmountMinor) * Number(rate);
  if (!Number.isFinite(value) || value > Number.MAX_SAFE_INTEGER) {
    throw conflict('LIQUIDITY_RATE_UNSUPPORTED', 'The liquidity order amount is too large');
  }
  return BigInt(Math.ceil(value));
}

async function releaseLiquidityOrder(
  client: PoolClient,
  input: { matchId: string; orderId: string; amountMinor: bigint },
): Promise<void> {
  const released = await client.query(
    `UPDATE p2p_matches
     SET liquidity_released_at = now()
     WHERE id = $1 AND liquidity_order_id = $2 AND liquidity_released_at IS NULL
     RETURNING id`,
    [input.matchId, input.orderId],
  );
  if (!released.rowCount) return;
  await client.query(
    `UPDATE liquidity_orders
     SET remaining_minor = LEAST(capacity_minor, remaining_minor + $2),
         status = CASE WHEN status = 'depleted' THEN 'active' ELSE status END
     WHERE id = $1`,
    [input.orderId, input.amountMinor.toString()],
  );
}

async function recordMatchEvent(
  client: PoolClient,
  input: { matchId: string; event: string; noteCode?: string; actor?: string },
): Promise<void> {
  await client.query(
    `INSERT INTO p2p_match_events (match_id, event, note_code, actor)
     VALUES ($1, $2, $3, $4)`,
    [input.matchId, input.event, input.noteCode ?? null, input.actor ?? 'system'],
  );
}

async function markMatch(
  client: PoolClient,
  input: { matchId: string; status: MatchRow['status']; event: string; noteCode?: string },
): Promise<void> {
  await client.query(
    `UPDATE p2p_matches
     SET status = $2,
         released_at = CASE WHEN $2 = 'released' THEN now() ELSE released_at END
     WHERE id = $1`,
    [input.matchId, input.status],
  );
  await recordMatchEvent(client, {
    matchId: input.matchId,
    event: input.event,
    noteCode: input.noteCode,
  });
}

function deadlineFor(trade: TradeRow, seconds: number): Date {
  return new Date(new Date(trade.created_at).getTime() + seconds * 1_000);
}

function covers(a: TradeRow, b: TradeRow): boolean {
  return (
    BigInt(a.send_amount_minor) >= BigInt(b.receive_amount_minor) &&
    BigInt(b.send_amount_minor) >= BigInt(a.receive_amount_minor)
  );
}

export interface MatchAttempt {
  matched: boolean;
  expired?: boolean;
  trade: TradeView;
  match?: MatchView;
}

/**
 * Finds the oldest eligible opposite funded trade and locks both. Trades are
 * collected before matching; only escrowed mobile-money trades enter the
 * queue. The whole decision is one transaction with row locks, so two workers
 * cannot double-match.
 */
export async function tryMatchTrade(
  ctx: AppContext,
  input: { tradeId: string; userId?: string },
): Promise<MatchAttempt> {
  if (!ctx.p2pEnabled) {
    throw serviceUnavailable('MATCHING_DISABLED', 'P2P matching is not enabled yet');
  }

  const outcome = await withTransaction(ctx.pool, async (client) => {
    const loaded = input.userId
      ? await client.query<TradeRow>(
          `SELECT * FROM trades WHERE id = $1 AND user_id = $2 FOR UPDATE`,
          [input.tradeId, input.userId],
        )
      : await client.query<TradeRow>(
          `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
          [input.tradeId],
        );
    const trade = loaded.rows[0];
    if (!trade) throw notFound('TRADE_NOT_FOUND', 'Trade not found');
    if (trade.route !== 'p2p') {
      throw conflict('CORRIDOR_NOT_MATCHABLE', 'This trade uses a bank payout, not P2P matching');
    }
    if (!['escrowed', 'matching'].includes(trade.status)) {
      throw conflict('TRADE_NOT_MATCHABLE', 'Only an escrowed trade can be matched');
    }

    const corridor = await loadCorridor(client, trade.send_currency, trade.receive_currency, true);
    if (!corridor || !corridor.enabled || corridor.exposure_cap_minor === null) {
      throw conflict('CORRIDOR_NOT_MATCHABLE', 'P2P matching is not enabled for this corridor');
    }
    if (
      corridor.min_amount_minor !== null &&
      BigInt(trade.send_amount_minor) < BigInt(corridor.min_amount_minor)
    ) {
      throw conflict('CORRIDOR_AMOUNT_OUT_OF_RANGE', 'The trade is below the corridor minimum');
    }
    if (
      corridor.max_amount_minor !== null &&
      BigInt(trade.send_amount_minor) > BigInt(corridor.max_amount_minor)
    ) {
      throw conflict('CORRIDOR_AMOUNT_OUT_OF_RANGE', 'The trade is above the corridor maximum');
    }

    const deadline = trade.match_deadline_at
      ? new Date(trade.match_deadline_at)
      : deadlineFor(trade, corridor.match_deadline_seconds);
    if (Date.now() > deadline.getTime()) {
      const expired = await setTradeStatus(client, {
        tradeId: trade.id,
        from: ['escrowed', 'matching'],
        to: 'expired',
        actor: 'server',
        failureCode: 'MATCH_TIMEOUT',
      });
      return { kind: 'expired' as const, trade: expired };
    }

    let current = trade;
    if (current.status === 'escrowed') {
      current = await setTradeStatus(client, {
        tradeId: current.id,
        from: ['escrowed'],
        to: 'matching',
        actor: 'server',
      });
    }
    await client.query(
      `UPDATE trades SET match_deadline_at = COALESCE(match_deadline_at, $2) WHERE id = $1`,
      [current.id, deadline],
    );

    const exposureCap = BigInt(corridor.exposure_cap_minor);
    const exposure = await openExposure(client, current.send_currency);
    if (exposure > exposureCap) {
      throw conflict('CORRIDOR_EXPOSURE_EXCEEDED', 'The corridor exposure cap is reached');
    }

    const candidates = await client.query<TradeRow>(
      `SELECT * FROM trades
       WHERE status IN ('escrowed', 'matching')
         AND route = 'p2p'
         AND id <> $1
         AND user_id <> $2
         AND send_currency = $3
         AND receive_currency = $4
         AND created_at > now() - interval '7 days'
       ORDER BY created_at, id
       FOR UPDATE SKIP LOCKED
       LIMIT 20`,
      [current.id, current.user_id, current.receive_currency, current.send_currency],
    );

    for (const candidate of candidates.rows) {
      const opposite = await loadCorridor(
        client,
        candidate.send_currency,
        candidate.receive_currency,
        true,
      );
      if (!opposite || !opposite.enabled || opposite.exposure_cap_minor === null) continue;
      const candidateDeadline = candidate.match_deadline_at
        ? new Date(candidate.match_deadline_at)
        : deadlineFor(candidate, opposite.match_deadline_seconds);
      if (Date.now() > candidateDeadline.getTime()) {
        if (candidate.status === 'escrowed' || candidate.status === 'matching') {
          await setTradeStatus(client, {
            tradeId: candidate.id,
            from: candidate.status === 'escrowed' ? ['escrowed'] : ['matching'],
            to: 'expired',
            actor: 'server',
            failureCode: 'MATCH_TIMEOUT',
          });
        }
        continue;
      }
      if (!covers(current, candidate)) continue;
      const candidateExposure = await openExposure(client, candidate.send_currency);
      if (candidateExposure > BigInt(opposite.exposure_cap_minor)) continue;

      const rate = (Number(candidate.send_amount_minor) / Number(current.send_amount_minor)).toFixed(10);
      const inserted = await client.query<MatchRow>(
        `INSERT INTO p2p_matches
           (buy_trade_id, sell_trade_id, buy_amount_minor, sell_amount_minor,
            buy_currency, sell_currency, status, matched_at, match_rate)
         VALUES ($1, $2, $3, $4, $5, $6, 'locked', now(), $7::numeric)
         RETURNING ${MATCH_COLUMNS}`,
        [
          current.id,
          candidate.id,
          current.send_amount_minor,
          candidate.send_amount_minor,
          current.send_currency,
          candidate.send_currency,
          rate,
        ],
      );
      const match = inserted.rows[0] as MatchRow;

      if (candidate.status === 'escrowed') {
        const queued = await setTradeStatus(client, {
          tradeId: candidate.id,
          from: ['escrowed'],
          to: 'matching',
          actor: 'server',
        });
        await setTradeStatus(client, {
          tradeId: queued.id,
          from: ['matching'],
          to: 'matched',
          actor: 'server',
        });
      } else {
        await setTradeStatus(client, {
          tradeId: candidate.id,
          from: ['matching'],
          to: 'matched',
          actor: 'server',
        });
      }
      current = await setTradeStatus(client, {
        tradeId: current.id,
        from: ['matching'],
        to: 'matched',
        actor: 'server',
      });
      await client.query(
        `UPDATE trades SET match_deadline_at = COALESCE(match_deadline_at, $2)
         WHERE id = $1`,
        [candidate.id, candidateDeadline],
      );
      await recordMatchEvent(client, {
        matchId: match.id,
        event: 'matched',
        noteCode: 'fifo_full_fill',
        actor: 'server',
      });
      return { kind: 'matched' as const, trade: current, match };
    }

    // No organic counterparty: try an allowlisted, pre-funded LP order. The
    // order provides the user's receive currency and is paid in the user's
    // send currency. A full-fill match never exceeds the order's remaining
    // prefunded capacity.
    const provideAmount = BigInt(current.receive_amount_minor);
    const order = await findLiquidityOrder(client, {
      provideCurrency: current.receive_currency,
      receiveCurrency: current.send_currency,
      provideAmountMinor: provideAmount,
    });
    if (order) {
      const lpReceive = receiveCost(provideAmount, order.rate);
      if (lpReceive <= BigInt(current.send_amount_minor)) {
        const rate = (Number(lpReceive) / Number(provideAmount)).toFixed(10);
        const inserted = await client.query<MatchRow>(
          `INSERT INTO p2p_matches
             (buy_trade_id, sell_trade_id, liquidity_order_id,
              buy_amount_minor, sell_amount_minor, buy_currency, sell_currency,
              status, matched_at, match_rate)
           VALUES ($1, NULL, $2, $3, $4, $5, $6, 'locked', now(), $7::numeric)
           RETURNING ${MATCH_COLUMNS}`,
          [
            current.id,
            order.id,
            current.send_amount_minor,
            provideAmount.toString(),
            current.send_currency,
            current.receive_currency,
            rate,
          ],
        );
        const match = inserted.rows[0] as MatchRow;
        await client.query(
          `UPDATE liquidity_orders
           SET remaining_minor = remaining_minor - $2,
               status = CASE WHEN remaining_minor - $2 <= 0 THEN 'depleted' ELSE status END
           WHERE id = $1`,
          [order.id, provideAmount.toString()],
        );
        current = await setTradeStatus(client, {
          tradeId: current.id,
          from: ['matching'],
          to: 'matched',
          actor: 'server',
        });
        await recordMatchEvent(client, {
          matchId: match.id,
          event: 'matched',
          noteCode: 'liquidity_provider',
          actor: 'server',
        });
        return { kind: 'matched' as const, trade: current, match };
      }
    }

    return { kind: 'queued' as const, trade: current };
  });

  if (outcome.kind === 'expired') {
    const refunded = await refundTrade(ctx, {
      tradeId: outcome.trade.id,
      userId: input.userId,
      reasonCode: 'match_timeout',
      allowClosed: false,
    });
    return { matched: false, expired: true, trade: refunded.trade };
  }
  if (outcome.kind === 'queued') {
    return { matched: false, trade: mapTrade(outcome.trade) };
  }
  return {
    matched: true,
    trade: mapTrade(outcome.trade),
    match: mapMatch(outcome.match),
  };
}

export interface MatchDisbursement {
  match: MatchView;
  legs: DisbursementResult[];
}

/**
 * Pays both legs. A match is only released when both providers confirm. If the
 * first leg fails, both customers are refunded and no settlement was posted.
 * If the second leg fails after the first paid, its own collected principal has
 * already funded the first payout, so CrossPay advances the shortfall and books
 * a `p2p_compensation` journal.
 */
export async function disburseMatch(
  ctx: AppContext,
  input: { matchId: string; userId?: string },
): Promise<MatchDisbursement> {
  if (!ctx.p2pEnabled) {
    throw serviceUnavailable('MATCHING_DISABLED', 'P2P matching is not enabled yet');
  }

  const prepared = await withTransaction(ctx.pool, async (client) => {
    const matchResult = await client.query<MatchRow>(
      `SELECT ${MATCH_COLUMNS} FROM p2p_matches WHERE id = $1 FOR UPDATE`,
      [input.matchId],
    );
    const match = matchResult.rows[0];
    if (!match) throw notFound('MATCH_NOT_FOUND', 'Match not found');
    if (input.userId) {
      const ownTradeId = match.liquidity_order_id ? match.buy_trade_id : null;
      if (ownTradeId) {
        const owns = await client.query(
          `SELECT 1 FROM trades WHERE id = $1 AND user_id = $2`,
          [ownTradeId, input.userId],
        );
        if (!owns.rowCount) throw notFound('MATCH_NOT_FOUND', 'Match not found');
      } else {
        const owns = await client.query(
          `SELECT 1 FROM trades
           WHERE id IN ($1, $2) AND user_id = $3`,
          [match.buy_trade_id, match.sell_trade_id, input.userId],
        );
        if (!owns.rowCount) throw notFound('MATCH_NOT_FOUND', 'Match not found');
      }
    }
    if (match.status === 'released') {
      return { kind: 'released' as const, match };
    }
    if (['failed', 'cancelled'].includes(match.status)) {
      throw conflict('MATCH_NOT_DISBURSABLE', 'This match can no longer be paid out');
    }

    if (match.liquidity_order_id) {
      const trade = await client.query<TradeRow>(
        `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
        [match.buy_trade_id],
      );
      const order = await client.query<LiquidityOrderRow>(
        `SELECT id, provider_id, provide_currency, receive_currency,
                capacity_minor, remaining_minor, min_amount_minor,
                max_amount_minor, rate, status, expires_at
         FROM liquidity_orders WHERE id = $1 FOR UPDATE`,
        [match.liquidity_order_id],
      );
      if (!trade.rows[0]) throw notFound('TRADE_NOT_FOUND', 'The matched trade is missing');
      if (!order.rows[0]) throw notFound('LIQUIDITY_ORDER_NOT_FOUND', 'Liquidity order missing');
      return {
        kind: 'liquidity' as const,
        match,
        trade: trade.rows[0],
        order: order.rows[0],
      };
    }

    const trades = await client.query<TradeRow>(
      `SELECT * FROM trades WHERE id IN ($1, $2) ORDER BY created_at, id FOR UPDATE`,
      [match.buy_trade_id, match.sell_trade_id],
    );
    if (trades.rowCount !== 2) throw notFound('TRADE_NOT_FOUND', 'A match trade is missing');
    return { kind: 'open' as const, match, trades: trades.rows };
  });

  if (prepared.kind === 'released') {
    return { match: mapMatch(prepared.match), legs: [] };
  }

  if (prepared.kind === 'liquidity') {
    if (['completed', 'refunded', 'failed'].includes(prepared.trade.status)) {
      await withTransaction(ctx.pool, async (client) => {
        await markMatch(client, {
          matchId: prepared.match.id,
          status: prepared.trade.status === 'completed' ? 'released' : 'failed',
          event: prepared.trade.status === 'completed' ? 'released' : 'failed',
          noteCode: 'liquidity_provider_terminal',
        });
        if (prepared.trade.status !== 'completed') {
          await releaseLiquidityOrder(client, {
            matchId: prepared.match.id,
            orderId: prepared.order.id,
            amountMinor: BigInt(prepared.match.sell_amount_minor),
          });
        }
      });
      return { match: await reloadMatch(ctx, prepared.match.id), legs: [] };
    }

    const result = await startDisbursement(ctx, {
      tradeId: prepared.trade.id,
      mode: 'match',
      matchId: prepared.match.id,
    });
    const legs = [result];
    if (result.payout.status === 'failed') {
      try {
        await refundTrade(ctx, {
          tradeId: prepared.trade.id,
          reasonCode: 'liquidity_payout_failed',
          allowClosed: false,
        });
      } finally {
        await withTransaction(ctx.pool, async (client) => {
          await releaseLiquidityOrder(client, {
            matchId: prepared.match.id,
            orderId: prepared.order.id,
            amountMinor: BigInt(prepared.match.sell_amount_minor),
          });
          await markMatch(client, {
            matchId: prepared.match.id,
            status: 'failed',
            event: 'failed',
            noteCode: 'liquidity_payout_failed',
          });
        });
      }
    } else if (result.payout.status === 'paid') {
      await withTransaction(ctx.pool, async (client) => {
        await markMatch(client, {
          matchId: prepared.match.id,
          status: 'released',
          event: 'released',
          noteCode: 'liquidity_provider_paid',
        });
      });
    }
    return { match: await reloadMatch(ctx, prepared.match.id), legs };
  }

  const [first, second] = prepared.trades;
  if (!first || !second) throw notFound('TRADE_NOT_FOUND', 'A match trade is missing');

  const firstResult = await startDisbursement(ctx, {
    tradeId: first.id,
    mode: 'match',
    matchId: prepared.match.id,
  });
  const legs: DisbursementResult[] = [firstResult];

  if (firstResult.payout.status === 'failed') {
    await failMatch(ctx, { match: prepared.match, first: first.id, second: second.id, reason: 'first_leg_failed' });
    return { match: await reloadMatch(ctx, prepared.match.id), legs };
  }
  if (firstResult.payout.status !== 'paid') {
    return { match: mapMatch(prepared.match), legs };
  }

  const secondResult = await startDisbursement(ctx, {
    tradeId: second.id,
    mode: 'match',
    matchId: prepared.match.id,
  });
  legs.push(secondResult);

  if (secondResult.payout.status === 'failed') {
    // The first payout used part of this trade's collected principal. Refund
    // the second customer normally, then advance the shortfall from treasury so
    // trust cash is not left negative.
    await refundTrade(ctx, {
      tradeId: second.id,
      reasonCode: 'match_counterparty_failed',
      allowClosed: false,
    });
    const shortfall = BigInt(first.receive_amount_minor);
    await postCompensation(ctx, {
      matchId: prepared.match.id,
      tradeId: second.id,
      currency: second.send_currency,
      amountMinor: shortfall,
    });
    await withTransaction(ctx.pool, async (client) => {
      await markMatch(client, {
        matchId: prepared.match.id,
        status: 'failed',
        event: 'failed',
        noteCode: 'second_leg_failed',
      });
    });
  } else if (secondResult.payout.status === 'paid') {
    await withTransaction(ctx.pool, async (client) => {
      await markMatch(client, {
        matchId: prepared.match.id,
        status: 'released',
        event: 'released',
        noteCode: 'both_legs_paid',
      });
    });
  }

  return { match: await reloadMatch(ctx, prepared.match.id), legs };
}

async function reloadMatch(ctx: AppContext, matchId: string): Promise<MatchView> {
  const row = await withTransaction(ctx.pool, async (client) => {
    const result = await client.query<MatchRow>(
      `SELECT ${MATCH_COLUMNS} FROM p2p_matches WHERE id = $1`,
      [matchId],
    );
    return result.rows[0];
  });
  if (!row) throw notFound('MATCH_NOT_FOUND', 'Match not found');
  return mapMatch(row);
}

async function failMatch(
  ctx: AppContext,
  input: { match: MatchRow; first: string; second: string; reason: string },
): Promise<void> {
  const failures: unknown[] = [];
  for (const tradeId of [input.first, input.second]) {
    try {
      await refundTrade(ctx, {
        tradeId,
        reasonCode: input.reason,
        allowClosed: false,
      });
    } catch (error) {
      failures.push(error);
    }
  }
  await withTransaction(ctx.pool, async (client) => {
    await markMatch(client, {
      matchId: input.match.id,
      status: 'failed',
      event: 'failed',
      noteCode: input.reason,
    });
  });
  // The match is terminal, but an unresolved refund is visible to the caller
  // and can be retried through the trade refund endpoint.
  if (failures.length > 0) throw failures[0];
}

async function postCompensation(
  ctx: AppContext,
  input: { matchId: string; tradeId: string; currency: string; amountMinor: bigint },
): Promise<void> {
  if (input.amountMinor <= 0n) return;
  await withTransaction(ctx.pool, async (client) => {
    const cash = await ledgerAccountId(client, { code: '1000', currency: input.currency });
    const funding = await ledgerAccountId(client, { code: '7000', currency: input.currency });
    await postJournalOnce(client, {
      postingKey: `match:${input.matchId}:compensate:${input.tradeId}`,
      kind: 'p2p_compensation',
      currencyCode: input.currency,
      tradeId: input.tradeId,
      fxGroupId: input.matchId,
      lines: [
        { accountId: cash, amountMinor: input.amountMinor },
        { accountId: funding, amountMinor: -input.amountMinor },
      ],
    });
  });
}
