import type { PoolClient } from 'pg';
import type { AppContext } from './http/context.js';
import { withTransaction } from './db/pool.js';
import { AppError, conflict, notFound, serviceUnavailable, unprocessable } from './http/errors.js';
import {
  PaymentRejectedError,
  PaymentUnavailableError,
  type PaymentPayout,
  type PaymentRefund,
} from './providers/payments.js';
import { postJournal, reverseJournal } from './ledger.js';
import {
  findJournalId,
  findTradeForUser,
  ledgerAccountId,
  mapTrade,
  postJournalOnce,
  setTradeStatus,
  type TradeRow,
  type TradeView,
} from './trades.js';

export interface PayoutRow {
  id: string;
  trade_id: string;
  provider: string;
  provider_reference: string | null;
  amount_minor: string;
  currency_code: string;
  status: 'pending' | 'submitted' | 'paid' | 'failed' | 'cancelled';
  attempt_count: number;
  last_error_code: string | null;
}

export interface RefundRow {
  id: string;
  trade_id: string;
  amount_minor: string;
  currency_code: string;
  reason_code: string;
  provider: string | null;
  provider_reference: string | null;
  status: 'pending' | 'submitted' | 'paid' | 'failed' | 'cancelled';
}

export interface PayoutView {
  id: string;
  status: PayoutRow['status'];
  providerReference: string | null;
  amountMinor: number;
  currency: string;
}

export interface RefundView {
  id: string;
  status: RefundRow['status'];
  providerReference: string | null;
  amountMinor: number;
  currency: string;
}

const PAYOUT_COLUMNS = `id, trade_id, provider, provider_reference, amount_minor,
                        currency_code, status, attempt_count, last_error_code`;
const REFUND_COLUMNS = `id, trade_id, amount_minor, currency_code, reason_code,
                        provider, provider_reference, status`;

export function mapPayout(row: PayoutRow): PayoutView {
  return {
    id: row.id,
    status: row.status,
    providerReference: row.provider_reference,
    amountMinor: Number(row.amount_minor),
    currency: row.currency_code,
  };
}

export function mapRefund(row: RefundRow): RefundView {
  return {
    id: row.id,
    status: row.status,
    providerReference: row.provider_reference,
    amountMinor: Number(row.amount_minor),
    currency: row.currency_code,
  };
}

/** Maps provider errors to the app-facing contract, never to a fake success. */
export function paymentFailure(error: unknown): never {
  if (error instanceof PaymentRejectedError) {
    throw new AppError(error.statusCode, error.code, error.message);
  }
  if (error instanceof PaymentUnavailableError) {
    if (error.code === 'PAYMENT_PROVIDER_NOT_CONFIGURED') {
      throw serviceUnavailable('PAYOUT_NOT_CONFIGURED', 'Payments are not connected yet');
    }
    throw serviceUnavailable(error.code, error.message);
  }
  throw error;
}

function providerOutcome(status: string): 'pending' | 'success' | 'failure' {
  const value = status.trim().toUpperCase();
  if (['SUCCESS', 'SUCCEEDED', 'COMPLETED', 'PAID', 'CONFIRMED', 'REFUNDED'].includes(value)) {
    return 'success';
  }
  if (
    ['FAILED', 'FAILURE', 'CANCELLED', 'CANCELED', 'EXPIRED', 'REJECTED', 'REVERSED'].includes(
      value,
    )
  ) {
    return 'failure';
  }
  return 'pending';
}

async function loadPayout(
  client: PoolClient,
  tradeId: string,
  forUpdate = false,
): Promise<PayoutRow | null> {
  const result = await client.query<PayoutRow>(
    `SELECT ${PAYOUT_COLUMNS}
     FROM payouts
     WHERE trade_id = $1
     ORDER BY created_at DESC, id DESC
     LIMIT 1${forUpdate ? ' FOR UPDATE' : ''}`,
    [tradeId],
  );
  return result.rows[0] ?? null;
}

export async function findPayoutByProviderReference(
  client: PoolClient,
  input: { provider: string; providerReference: string; forUpdate?: boolean },
): Promise<PayoutRow | null> {
  const result = await client.query<PayoutRow>(
    `SELECT ${PAYOUT_COLUMNS}
     FROM payouts
     WHERE provider = $1 AND provider_reference = $2${input.forUpdate ? ' FOR UPDATE' : ''}`,
    [input.provider, input.providerReference],
  );
  return result.rows[0] ?? null;
}

async function loadRefund(
  client: PoolClient,
  tradeId: string,
  forUpdate = false,
): Promise<RefundRow | null> {
  const result = await client.query<RefundRow>(
    `SELECT ${REFUND_COLUMNS}
     FROM refunds
     WHERE trade_id = $1
     ORDER BY created_at DESC, id DESC
     LIMIT 1${forUpdate ? ' FOR UPDATE' : ''}`,
    [tradeId],
  );
  return result.rows[0] ?? null;
}

async function railKind(
  client: PoolClient,
  railId: string,
): Promise<'mobile_money' | 'bank'> {
  const result = await client.query<{ kind: 'mobile_money' | 'bank' }>(
    `SELECT kind FROM payout_rails WHERE id = $1 AND active`,
    [railId],
  );
  const kind = result.rows[0]?.kind;
  if (!kind) throw unprocessable('RECIPIENT_REJECTED', 'The payout rail is no longer available');
  return kind;
}

/** Posts the FX and payout journals exactly once for one payout. */
async function postPayoutLedgers(
  client: PoolClient,
  input: {
    trade: TradeRow;
    payout: PayoutRow;
    providerFeeMinor: bigint;
    mode: DisbursementMode;
    matchId?: string;
    counterpart?: TradeRow;
  },
): Promise<void> {
  const { trade, payout, providerFeeMinor, mode } = input;
  const sendAmount = BigInt(trade.send_amount_minor);
  const receiveAmount = BigInt(trade.receive_amount_minor);

  const receivePayable = await ledgerAccountId(client, {
    code: '2000',
    currency: trade.receive_currency,
  });
  const receiveCash = await ledgerAccountId(client, {
    code: '1000',
    currency: trade.receive_currency,
  });

  if (mode === 'direct') {
    const sendPayable = await ledgerAccountId(client, {
      code: '2000',
      currency: trade.send_currency,
    });
    const sendFxClearing = await ledgerAccountId(client, {
      code: '5000',
      currency: trade.send_currency,
    });
    const receiveFxClearing = await ledgerAccountId(client, {
      code: '5000',
      currency: trade.receive_currency,
    });

    // Two linked single-currency journals. They are never summed together: the
    // FX clearing account is the bridge, and fx_group_id is the only link.
    await postJournalOnce(client, {
      postingKey: `trade:${trade.id}:fx:source`,
      kind: 'fx_conversion',
      currencyCode: trade.send_currency,
      tradeId: trade.id,
      payoutId: payout.id,
      fxGroupId: payout.id,
      lines: [
        { accountId: sendPayable, amountMinor: sendAmount },
        { accountId: sendFxClearing, amountMinor: -sendAmount },
      ],
    });

    await postJournalOnce(client, {
      postingKey: `trade:${trade.id}:fx:destination`,
      kind: 'fx_conversion',
      currencyCode: trade.receive_currency,
      tradeId: trade.id,
      payoutId: payout.id,
      fxGroupId: payout.id,
      lines: [
        { accountId: receiveFxClearing, amountMinor: receiveAmount },
        { accountId: receivePayable, amountMinor: -receiveAmount },
      ],
    });
  } else {
    const matchId = input.matchId;
    const counterpart = input.counterpart;
    if (!matchId || !counterpart) {
      throw new AppError(500, 'MATCH_CONTEXT_MISSING', 'The matched payout has no counterpart');
    }
    if (counterpart.send_currency !== trade.receive_currency) {
      throw new AppError(500, 'MATCH_CURRENCY_MISMATCH', 'The match legs do not line up');
    }
    const sourceAmount = BigInt(counterpart.send_amount_minor);
    if (sourceAmount < receiveAmount) {
      throw new AppError(409, 'MATCH_UNDERFUNDED', 'The counterpart does not cover this payout');
    }
    const spread = sourceAmount - receiveAmount;
    const spreadRevenue =
      spread > 0n
        ? await ledgerAccountId(client, { code: '3100', currency: trade.receive_currency })
        : null;

    // The counterpart's collected principal pays this leg. Both sides remain
    // in the same currency, so this is a P2P settlement, not an FX conversion.
    await postJournalOnce(client, {
      postingKey: `match:${matchId}:settle:${trade.id}`,
      kind: 'p2p_settlement',
      currencyCode: trade.receive_currency,
      tradeId: trade.id,
      payoutId: payout.id,
      fxGroupId: matchId,
      lines: [
        { accountId: receivePayable, amountMinor: sourceAmount },
        { accountId: receivePayable, amountMinor: -receiveAmount },
        ...(spreadRevenue && spread > 0n
          ? [{ accountId: spreadRevenue, amountMinor: -spread }]
          : []),
      ],
    });
  }

  if (providerFeeMinor > 0n) {
    const payoutExpense = await ledgerAccountId(client, {
      code: '6000',
      currency: trade.receive_currency,
    });
    await postJournalOnce(client, {
      postingKey: `trade:${trade.id}:payout`,
      kind: 'payout_sent',
      currencyCode: trade.receive_currency,
      tradeId: trade.id,
      payoutId: payout.id,
      lines: [
        { accountId: receivePayable, amountMinor: receiveAmount },
        { accountId: payoutExpense, amountMinor: providerFeeMinor },
        { accountId: receiveCash, amountMinor: -(receiveAmount + providerFeeMinor) },
      ],
    });
    return;
  }

  await postJournalOnce(client, {
    postingKey: `trade:${trade.id}:payout`,
    kind: 'payout_sent',
    currencyCode: trade.receive_currency,
    tradeId: trade.id,
    payoutId: payout.id,
    lines: [
      { accountId: receivePayable, amountMinor: receiveAmount },
      { accountId: receiveCash, amountMinor: -receiveAmount },
    ],
  });
}

export interface DisbursementResult {
  trade: TradeView;
  payout: PayoutView;
}

/**
 * Starts or resumes a payout for an escrowed trade.
 *
 * The trade first takes the generic matching path so a later P2P engine can
 * replace the direct-liquidity step without changing the payout saga. The
 * provider call happens outside the database transaction; the deterministic
 * provider reference makes a retry after a crash safe.
 */
export type DisbursementMode = 'direct' | 'match';

export interface DisbursementInput {
  /** The signed-in owner for the app route; omitted for the match saga. */
  userId?: string;
  tradeId: string;
  mode?: DisbursementMode;
  matchId?: string;
}

/**
 * Starts or resumes a payout for an escrowed/matched trade.
 *
 * `direct` pays from CrossPay liquidity and posts the two FX journals. `match`
 * is called by the P2P saga and pays from the counterpart's collected
 * principal, so it posts a single-currency `p2p_settlement` journal instead.
 * The provider call happens outside the database transaction; the
 * deterministic provider reference makes a retry after a crash safe.
 */
export async function startDisbursement(
  ctx: AppContext,
  input: DisbursementInput,
): Promise<DisbursementResult> {
  const mode = input.mode ?? 'direct';
  const prepared = await withTransaction(ctx.pool, async (client) => {
    let trade: TradeRow;
    if (input.userId) {
      trade = await findTradeForUser(client, {
        userId: input.userId,
        tradeId: input.tradeId,
        forUpdate: true,
      });
    } else {
      const rows = await client.query<TradeRow>(
        `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
        [input.tradeId],
      );
      if (!rows.rows[0]) throw notFound('TRADE_NOT_FOUND', 'Trade not found');
      trade = rows.rows[0];
    }

    if (trade.status === 'completed') {
      const payout = await loadPayout(client, trade.id);
      if (payout) return { done: true as const, trade, payout, counterpart: null };
    }
    if (['cancelled', 'refunded', 'failed', 'expired'].includes(trade.status)) {
      throw conflict('TRADE_NOT_DISBURSABLE', 'This trade can no longer be paid out');
    }
    if (trade.status === 'pending_deposit') {
      throw conflict('PAYMENT_NOT_CONFIRMED', 'The customer payment has not arrived yet');
    }
    if ((await railKind(client, trade.beneficiary_rail_id)) !== 'mobile_money') {
      throw serviceUnavailable(
        'PAYOUT_RAIL_NOT_CONFIGURED',
        'Bank payouts are not connected yet',
      );
    }

    let counterpart: TradeRow | null = null;
    if (mode === 'match') {
      if (!input.matchId) {
        throw conflict('MATCH_REQUIRED', 'A matched payout needs a match id');
      }
      const match = await client.query<{
        id: string;
        buy_trade_id: string;
        sell_trade_id: string;
        status: string;
      }>(
        `SELECT id, buy_trade_id, sell_trade_id, status
         FROM p2p_matches WHERE id = $1 FOR UPDATE`,
        [input.matchId],
      );
      const row = match.rows[0];
      if (!row) throw notFound('MATCH_NOT_FOUND', 'Match not found');
      if (['failed', 'cancelled'].includes(row.status)) {
        throw conflict('MATCH_NOT_DISBURSABLE', 'This match can no longer be paid out');
      }
      if (row.buy_trade_id !== trade.id && row.sell_trade_id !== trade.id) {
        throw conflict('MATCH_MISMATCH', 'The trade does not belong to this match');
      }
      if (!['matched', 'disbursing'].includes(trade.status)) {
        throw conflict('TRADE_NOT_DISBURSABLE', 'The trade is not in a matched state');
      }
      const counterpartId =
        row.buy_trade_id === trade.id ? row.sell_trade_id : row.buy_trade_id;
      const opposite = await client.query<TradeRow>(
        `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
        [counterpartId],
      );
      counterpart = opposite.rows[0] ?? null;
      if (!counterpart) throw notFound('TRADE_NOT_FOUND', 'The counterpart trade is missing');
    } else {
      if (trade.status === 'escrowed') {
        trade = await setTradeStatus(client, {
          tradeId: trade.id,
          from: ['escrowed'],
          to: 'matching',
          actor: 'server',
        });
      }
      if (trade.status === 'matching') {
        trade = await setTradeStatus(client, {
          tradeId: trade.id,
          from: ['matching'],
          to: 'matched',
          actor: 'server',
        });
      }
    }

    let payout = await loadPayout(client, trade.id, true);
    if (!payout) {
      const inserted = await client.query<PayoutRow>(
        `INSERT INTO payouts
           (trade_id, provider, amount_minor, currency_code, status)
         VALUES ($1, $2, $3, $4, 'pending')
         RETURNING ${PAYOUT_COLUMNS}`,
        [
          trade.id,
          ctx.paymentProvider.name,
          trade.receive_amount_minor,
          trade.receive_currency,
        ],
      );
      payout = inserted.rows[0] as PayoutRow;
    }
    if (payout.status === 'paid') {
      return { done: true as const, trade, payout, counterpart };
    }

    return { done: false as const, trade, payout, counterpart };
  });

  if (prepared.done) {
    return { trade: mapTrade(prepared.trade), payout: mapPayout(prepared.payout) };
  }

  const account = ctx.crypto.decrypt(prepared.trade.beneficiary_account_encrypted);
  const providerReference = `${prepared.trade.reference}-OUT`;

  let snapshot: PaymentPayout | null = null;
  if (prepared.payout.provider_reference) {
    snapshot = await ctx.paymentProvider
      .getPayout(prepared.payout.provider_reference)
      .catch(paymentFailure);
  }
  if (!snapshot) {
    try {
      snapshot = await ctx.paymentProvider.createPayout({
        phoneNumber: account,
        amountMinor: Number(prepared.trade.receive_amount_minor),
        currency: prepared.trade.receive_currency,
        transactionRef: providerReference,
        callbackUrl: ctx.paymentCallbackUrl,
      });
    } catch (error) {
      if (error instanceof PaymentRejectedError) {
        if (mode === 'match') {
          await markPayoutFailed(ctx, {
            payoutId: prepared.payout.id,
            errorCode: error.code,
          });
          return readDisbursement(ctx, prepared.payout.id);
        }
        await failPayout(ctx, {
          payoutId: prepared.payout.id,
          errorCode: error.code,
        });
        // The provider refused before paying. Return the customer's money
        // instead of leaving the trade matched forever.
        await refundTrade(ctx, {
          tradeId: prepared.trade.id,
          reasonCode: 'payout_rejected',
          allowClosed: false,
        });
        paymentFailure(error);
      }
      paymentFailure(error);
    }
  }

  return applyPayoutSnapshot(ctx, {
    payoutId: prepared.payout.id,
    snapshot,
    mode,
    matchId: input.matchId,
  });
}

async function readDisbursement(
  ctx: AppContext,
  payoutId: string,
): Promise<DisbursementResult> {
  const row = await withTransaction(ctx.pool, async (client) => {
    const payout = await client.query<PayoutRow>(
      `SELECT ${PAYOUT_COLUMNS} FROM payouts WHERE id = $1`,
      [payoutId],
    );
    const found = payout.rows[0];
    if (!found) return { payout: undefined, trade: undefined };
    const trade = await client.query<TradeRow>(
      `SELECT * FROM trades WHERE id = $1`,
      [found.trade_id],
    );
    return { payout: found, trade: trade.rows[0] };
  });
  if (!row.payout || !row.trade) throw notFound('PAYOUT_NOT_FOUND', 'Payout not found');
  return { trade: mapTrade(row.trade), payout: mapPayout(row.payout) };
}

async function markPayoutFailed(
  ctx: AppContext,
  input: { payoutId: string; errorCode: string },
): Promise<void> {
  await withTransaction(ctx.pool, async (client) => {
    const locked = await client.query<PayoutRow>(
      `SELECT ${PAYOUT_COLUMNS} FROM payouts WHERE id = $1 FOR UPDATE`,
      [input.payoutId],
    );
    const payout = locked.rows[0];
    if (!payout) return;
    const trade = await client.query<TradeRow>(
      `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
      [payout.trade_id],
    );
    await client.query(
      `UPDATE payouts
       SET status = 'failed', last_error_code = $2, completed_at = now()
       WHERE id = $1 AND status IN ('pending', 'submitted')`,
      [payout.id, input.errorCode.slice(0, 64)],
    );
    const row = trade.rows[0];
    if (row) {
      if (row.status === 'matched') {
        await setTradeStatus(client, {
          tradeId: row.id,
          from: ['matched'],
          to: 'disbursing',
          actor: 'provider',
        });
      }
      if (row.status === 'matched' || row.status === 'disbursing') {
        await setTradeStatus(client, {
          tradeId: row.id,
          from: ['disbursing'],
          to: 'failed',
          actor: 'provider',
          failureCode: 'PAYOUT_FAILED',
        });
      }
    }
  });
}

/** Applies one provider payout snapshot. Safe to call again with the same data. */
export async function applyPayoutSnapshot(
  ctx: AppContext,
  input: {
    payoutId: string;
    snapshot: PaymentPayout;
    mode?: DisbursementMode;
    matchId?: string;
  },
): Promise<DisbursementResult> {
  const mode = input.mode ?? 'direct';
  const applied = await withTransaction(ctx.pool, async (client) => {
    const locked = await client.query<PayoutRow>(
      `SELECT ${PAYOUT_COLUMNS} FROM payouts WHERE id = $1 FOR UPDATE`,
      [input.payoutId],
    );
    const payout = locked.rows[0];
    if (!payout) throw notFound('PAYOUT_NOT_FOUND', 'Payout not found');
    const tradeResult = await client.query<TradeRow>(
      `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
      [payout.trade_id],
    );
    const trade = tradeResult.rows[0];
    if (!trade) throw notFound('TRADE_NOT_FOUND', 'Trade not found');

    let counterpart: TradeRow | null = null;
    if (mode === 'match') {
      if (!input.matchId) throw conflict('MATCH_REQUIRED', 'The matched payout has no match id');
      const match = await client.query<{ buy_trade_id: string; sell_trade_id: string }>(
        `SELECT buy_trade_id, sell_trade_id FROM p2p_matches WHERE id = $1`,
        [input.matchId],
      );
      const row = match.rows[0];
      if (!row) throw notFound('MATCH_NOT_FOUND', 'Match not found');
      const counterpartId =
        row.buy_trade_id === trade.id ? row.sell_trade_id : row.buy_trade_id;
      const opposite = await client.query<TradeRow>(
        `SELECT * FROM trades WHERE id = $1`,
        [counterpartId],
      );
      counterpart = opposite.rows[0] ?? null;
      if (!counterpart) throw notFound('TRADE_NOT_FOUND', 'The counterpart trade is missing');
    }

    if (payout.status === 'paid' || trade.status === 'completed') {
      return { kind: 'paid' as const, trade, payout };
    }
    if (payout.status === 'failed') {
      return { kind: 'failed' as const, trade, payout };
    }
    if (['refunded', 'cancelled'].includes(trade.status)) {
      return { kind: 'ignored' as const, trade, payout };
    }

    if (input.snapshot.currency !== payout.currency_code) {
      throw new AppError(
        502,
        'PAYOUT_CURRENCY_MISMATCH',
        'The payout provider reported a different currency',
      );
    }
    if (BigInt(input.snapshot.amountMinor) !== BigInt(payout.amount_minor)) {
      throw new AppError(
        502,
        'PAYOUT_AMOUNT_MISMATCH',
        'The payout provider reported a different amount',
      );
    }

    await client.query(
      `UPDATE payouts
       SET provider_reference = COALESCE(provider_reference, $2),
           attempt_count = attempt_count + 1,
           last_error_code = NULL
       WHERE id = $1`,
      [payout.id, input.snapshot.payoutId],
    );

    const outcome = providerOutcome(input.snapshot.status);
    if (outcome === 'pending') {
      await client.query(
        `UPDATE payouts SET status = 'submitted' WHERE id = $1 AND status = 'pending'`,
        [payout.id],
      );
      if (trade.status === 'matched') {
        await setTradeStatus(client, {
          tradeId: trade.id,
          from: ['matched'],
          to: 'disbursing',
          actor: 'provider',
        });
      }
      return { kind: 'pending' as const, trade, payout };
    }

    if (outcome === 'failure') {
      await client.query(
        `UPDATE payouts
         SET status = 'failed', last_error_code = 'PAYOUT_FAILED', completed_at = now()
         WHERE id = $1 AND status IN ('pending', 'submitted')`,
        [payout.id],
      );
      if (trade.status === 'matched') {
        await setTradeStatus(client, {
          tradeId: trade.id,
          from: ['matched'],
          to: 'disbursing',
          actor: 'provider',
        });
      }
      const failedTrade = await setTradeStatus(client, {
        tradeId: trade.id,
        from: ['disbursing'],
        to: 'failed',
        actor: 'provider',
        failureCode: 'PAYOUT_FAILED',
      });
      return { kind: 'failed' as const, trade: failedTrade, payout };
    }

    await postPayoutLedgers(client, {
      trade,
      payout,
      providerFeeMinor: BigInt(input.snapshot.feeMinor ?? 0),
      mode,
      matchId: input.matchId,
      counterpart: counterpart ?? undefined,
    });
    await client.query(
      `UPDATE payouts SET status = 'paid', completed_at = now()
       WHERE id = $1 AND status IN ('pending', 'submitted')`,
      [payout.id],
    );
    let completed = trade;
    if (trade.status === 'matched') {
      completed = await setTradeStatus(client, {
        tradeId: trade.id,
        from: ['matched'],
        to: 'disbursing',
        actor: 'provider',
      });
    }
    completed = await setTradeStatus(client, {
      tradeId: trade.id,
      from: ['disbursing'],
      to: 'completed',
      actor: 'provider',
    });
    return { kind: 'paid' as const, trade: completed, payout };
  });

  if (applied.kind === 'failed' && mode === 'direct') {
    await refundTrade(ctx, {
      tradeId: applied.trade.id,
      reasonCode: 'payout_failed',
      allowClosed: false,
    });
  }

  const refreshed = await withTransaction(ctx.pool, async (client) => {
    const trade = await client.query<TradeRow>('SELECT * FROM trades WHERE id = $1', [
      applied.trade.id,
    ]);
    const payout = await client.query<PayoutRow>(
      `SELECT ${PAYOUT_COLUMNS} FROM payouts WHERE id = $1`,
      [input.payoutId],
    );
    return { trade: trade.rows[0] as TradeRow, payout: payout.rows[0] as PayoutRow };
  });

  return { trade: mapTrade(refreshed.trade), payout: mapPayout(refreshed.payout) };
}

async function failPayout(
  ctx: AppContext,
  input: { payoutId: string; errorCode: string },
): Promise<void> {
  await withTransaction(ctx.pool, async (client) => {
    const locked = await client.query<PayoutRow>(
      `SELECT ${PAYOUT_COLUMNS} FROM payouts WHERE id = $1 FOR UPDATE`,
      [input.payoutId],
    );
    const payout = locked.rows[0];
    if (!payout) return;
    await client.query(
      `UPDATE payouts
       SET status = 'failed', last_error_code = $2, completed_at = now()
       WHERE id = $1 AND status IN ('pending', 'submitted')`,
      [payout.id, input.errorCode.slice(0, 64)],
    );
  });
}

/**
 * Refunds a confirmed collection in full and reverses both collection
 * journals. It is also the compensation path for a payout failure and for a
 * late collection that arrives after the sender cancelled.
 */
export async function refundTrade(
  ctx: AppContext,
  input: {
    tradeId: string;
    userId?: string;
    reasonCode: string;
    allowClosed: boolean;
  },
): Promise<{ trade: TradeView; refund: RefundView }> {
  const prepared = await withTransaction(ctx.pool, async (client) => {
    const trade = input.userId
      ? await findTradeForUser(client, {
          userId: input.userId,
          tradeId: input.tradeId,
          forUpdate: true,
        })
      : (
          await client.query<TradeRow>(
            `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
            [input.tradeId],
          )
        ).rows[0];
    if (!trade) throw notFound('TRADE_NOT_FOUND', 'Trade not found');

    if (trade.status === 'completed') {
      throw conflict('PAYOUT_ALREADY_SENT', 'The money was already paid out; open a dispute');
    }
    if (trade.status === 'refunded') {
      const existing = await loadRefund(client, trade.id);
      if (existing) return { done: true as const, trade, refund: existing };
    }
    if (trade.status === 'cancelled' && !input.allowClosed) {
      throw conflict('CANNOT_REFUND', 'This trade has no confirmed collection to refund');
    }

    const attempt = await client.query<{
      id: string;
      external_reference: string | null;
      amount_minor: string;
      currency_code: string;
      status: string;
    }>(
      `SELECT id, external_reference, amount_minor, currency_code, status
       FROM payment_attempts
       WHERE trade_id = $1 AND external_reference IS NOT NULL
       ORDER BY created_at DESC, id DESC
       LIMIT 1
       FOR UPDATE`,
      [trade.id],
    );
    const row = attempt.rows[0];
    if (!row || row.status !== 'confirmed') {
      throw conflict('NOT_REFUNDABLE', 'No confirmed collection exists for this trade');
    }

    let refund = await loadRefund(client, trade.id, true);
    if (refund && ['paid', 'submitted', 'pending'].includes(refund.status)) {
      return { done: false as const, trade, refund, requestId: row.external_reference };
    }
    if (!refund) {
      const inserted = await client.query<RefundRow>(
        `INSERT INTO refunds
           (trade_id, amount_minor, currency_code, reason_code, provider, status)
         VALUES ($1, $2, $3, $4, $5, 'pending')
         RETURNING ${REFUND_COLUMNS}`,
        [
          trade.id,
          row.amount_minor,
          row.currency_code,
          input.reasonCode,
          ctx.paymentProvider.name,
        ],
      );
      refund = inserted.rows[0] as RefundRow;
    }
    return { done: false as const, trade, refund, requestId: row.external_reference };
  });

  if (prepared.done) {
    return { trade: mapTrade(prepared.trade), refund: mapRefund(prepared.refund) };
  }
  if (!prepared.requestId) {
    throw conflict('NOT_REFUNDABLE', 'No provider collection to refund');
  }

  let snapshot: PaymentRefund;
  try {
    snapshot = await ctx.paymentProvider.refund({
      requestId: prepared.requestId,
      amountMinor: Number(prepared.refund.amount_minor),
      reason: input.reasonCode,
    });
  } catch (error) {
    if (error instanceof PaymentRejectedError) {
      await withTransaction(ctx.pool, async (client) => {
        await client.query(
          `UPDATE refunds
           SET status = 'failed', completed_at = now()
           WHERE id = $1 AND status IN ('pending', 'submitted')`,
          [prepared.refund.id],
        );
      });
    }
    paymentFailure(error);
  }

  if (
    snapshot.currency !== prepared.refund.currency_code ||
    BigInt(snapshot.amountMinor) !== BigInt(prepared.refund.amount_minor)
  ) {
    throw new AppError(
      502,
      'REFUND_MISMATCH',
      'The refund provider reported a different amount or currency',
    );
  }
  if (providerOutcome(snapshot.status) !== 'success') {
    throw new AppError(502, 'REFUND_NOT_CONFIRMED', 'The refund provider did not confirm');
  }

  const applied = await withTransaction(ctx.pool, async (client) => {
    const lockedRefund = await client.query<RefundRow>(
      `SELECT ${REFUND_COLUMNS} FROM refunds WHERE id = $1 FOR UPDATE`,
      [prepared.refund.id],
    );
    const refund = lockedRefund.rows[0];
    if (!refund) throw notFound('REFUND_NOT_FOUND', 'Refund not found');
    if (refund.status === 'paid') {
      const tradeRow = (
        await client.query<TradeRow>('SELECT * FROM trades WHERE id = $1', [refund.trade_id])
      ).rows[0] as TradeRow;
      return { trade: tradeRow, refund };
    }

    const tradeResult = await client.query<TradeRow>(
      `SELECT * FROM trades WHERE id = $1 FOR UPDATE`,
      [refund.trade_id],
    );
    const trade = tradeResult.rows[0];
    if (!trade) throw notFound('TRADE_NOT_FOUND', 'Trade not found');

    await client.query(
      `UPDATE refunds
       SET status = 'paid', provider_reference = $2, completed_at = now()
       WHERE id = $1`,
      [refund.id, snapshot.refundId],
    );

    const deposit = await findJournalId(client, `trade:${trade.id}:deposit`);
    if (!deposit) {
      throw new AppError(503, 'LEDGER_NOT_CONFIGURED', 'The collection journal is missing');
    }
    await reverseJournal(client, {
      originalTransactionId: deposit,
      postingKey: `trade:${trade.id}:refund:deposit`,
      refundId: refund.id,
      kind: 'refund_paid',
    });
    const fee = await findJournalId(client, `trade:${trade.id}:fee`);
    if (fee) {
      await reverseJournal(client, {
        originalTransactionId: fee,
        postingKey: `trade:${trade.id}:refund:fee`,
        refundId: refund.id,
        kind: 'refund_paid',
      });
    }

    let refunded = trade;
    if (trade.status !== 'cancelled' && trade.status !== 'refunded') {
      refunded = await setTradeStatus(client, {
        tradeId: trade.id,
        from: ['escrowed', 'matching', 'matched', 'disbursing', 'failed', 'expired'],
        to: 'refunded',
        actor: 'server',
        failureCode: input.reasonCode.toUpperCase().slice(0, 64),
      });
    }
    return { trade: refunded, refund: { ...refund, status: 'paid' as const } };
  });

  return { trade: mapTrade(applied.trade), refund: mapRefund(applied.refund) };
}
