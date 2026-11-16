import { createHash } from 'node:crypto';
import type { Pool, PoolClient } from 'pg';
import type { PaymentCollection } from './providers/payments.js';
import { AppError, conflict, notFound, unprocessable } from './http/errors.js';
import { postJournal, type JournalKind } from './ledger.js';

export type TradeStatus =
  | 'pending_deposit'
  | 'escrowed'
  | 'matching'
  | 'matched'
  | 'disbursing'
  | 'completed'
  | 'expired'
  | 'refunded'
  | 'failed'
  | 'cancelled';

export type TradeRoute = 'p2p' | 'bank';

export interface TradeRow {
  id: string;
  reference: string;
  user_id: string;
  quote_id: string;
  quote_route_id: string;
  route: TradeRoute;
  status: TradeStatus;
  send_currency: string;
  receive_currency: string;
  send_amount_minor: string;
  fee_minor: string;
  fee_bps: number;
  receive_amount_minor: string;
  rate: string;
  beneficiary_name: string;
  beneficiary_rail_id: string;
  beneficiary_account_encrypted: Buffer;
  beneficiary_account_last4: string;
  beneficiary_reference: string | null;
  verification_hash: string | null;
  current_payment_attempt_id: string | null;
  failure_code: string | null;
  match_deadline_at: Date | null;
  created_at: Date;
  updated_at: Date;
  completed_at: Date | null;
  cancelled_at: Date | null;
}

export interface TradeView {
  id: string;
  reference: string;
  route: TradeRoute;
  status: TradeStatus;
  sendCurrency: string;
  receiveCurrency: string;
  sendAmountMinor: number;
  feeMinor: number;
  feeBps: number;
  receiveAmountMinor: number;
  rate: number;
  beneficiaryName: string;
  createdAt: string;
  verificationHash?: string;
}

export interface QuoteRouteRow {
  id: string;
  route: TradeRoute;
  fee_bps: number;
  fee_minor: string;
  payout_minor: string;
  total_debit_minor: string;
  is_available: boolean;
}

export interface PaymentAttemptRow {
  id: string;
  trade_id: string;
  provider: string;
  external_reference: string | null;
  method: 'push' | 'manual';
  amount_minor: string;
  currency_code: string;
  push_sent: boolean;
  network_name: string | null;
  push_timeout_seconds: number | null;
  poll_interval_seconds: number | null;
  status: 'pending' | 'sent' | 'confirmed' | 'failed' | 'expired';
}

export const TRADE_COLUMNS = `id, reference, user_id, quote_id, quote_route_id, route, status,
  send_currency, receive_currency, send_amount_minor, fee_minor, fee_bps,
  receive_amount_minor, rate, beneficiary_name, beneficiary_rail_id,
  beneficiary_account_encrypted, beneficiary_account_last4, beneficiary_reference,
  verification_hash, current_payment_attempt_id, failure_code, match_deadline_at,
  created_at, updated_at, completed_at, cancelled_at`;

const ATTEMPT_COLUMNS = `id, trade_id, provider, external_reference, method, amount_minor,
  currency_code, push_sent, network_name, push_timeout_seconds,
  poll_interval_seconds, status`;

export function mapTrade(row: TradeRow): TradeView {
  const view: TradeView = {
    id: row.id,
    reference: row.reference,
    route: row.route,
    status: row.status,
    sendCurrency: row.send_currency,
    receiveCurrency: row.receive_currency,
    sendAmountMinor: Number(row.send_amount_minor),
    feeMinor: Number(row.fee_minor),
    feeBps: row.fee_bps,
    receiveAmountMinor: Number(row.receive_amount_minor),
    rate: Number(row.rate),
    beneficiaryName: row.beneficiary_name,
    createdAt: new Date(row.created_at).toISOString(),
  };
  if (row.verification_hash !== null) view.verificationHash = row.verification_hash;
  return view;
}

export async function findTradeForUser(
  db: Pool | PoolClient,
  input: { userId: string; tradeId: string; forUpdate?: boolean },
): Promise<TradeRow> {
  const result = await db.query<TradeRow>(
    `SELECT ${TRADE_COLUMNS}
     FROM trades
     WHERE id = $1 AND user_id = $2${input.forUpdate ? ' FOR UPDATE' : ''}`,
    [input.tradeId, input.userId],
  );
  const row = result.rows[0];
  if (!row) throw notFound('TRADE_NOT_FOUND', 'Trade not found');
  return row;
}

/**
 * Resolves the trade behind a provider callback. The provider only knows its
 * own checkout id, so this lookup is the bridge from a webhook to CrossPay's
 * durable trade.
 */
export async function findTradeByAttemptReference(
  client: PoolClient,
  input: { provider: string; externalReference: string; forUpdate?: boolean },
): Promise<TradeRow | null> {
  const result = await client.query<TradeRow>(
    `SELECT t.*
     FROM trades t
     JOIN payment_attempts a ON a.trade_id = t.id
     WHERE a.provider = $1 AND a.external_reference = $2
     ORDER BY a.created_at DESC, a.id DESC
     LIMIT 1${input.forUpdate ? ' FOR UPDATE OF t' : ''}`,
    [input.provider, input.externalReference],
  );
  return result.rows[0] ?? null;
}

export async function findJournalId(
  client: PoolClient,
  postingKey: string,
): Promise<string | null> {
  const result = await client.query<{ id: string }>(
    `SELECT id FROM journal_transactions WHERE posting_key = $1`,
    [postingKey],
  );
  return result.rows[0]?.id ?? null;
}

export async function findPaymentAttemptByReference(
  client: PoolClient,
  input: { provider: string; externalReference: string; forUpdate?: boolean },
): Promise<PaymentAttemptRow | null> {
  const result = await client.query<PaymentAttemptRow>(
    `SELECT ${ATTEMPT_COLUMNS}
     FROM payment_attempts
     WHERE provider = $1 AND external_reference = $2
     ORDER BY created_at DESC, id DESC
     LIMIT 1${input.forUpdate ? ' FOR UPDATE' : ''}`,
    [input.provider, input.externalReference],
  );
  return result.rows[0] ?? null;
}

export async function listTradesForUser(
  db: Pool | PoolClient,
  input: { userId: string; limit: number },
): Promise<TradeView[]> {
  const result = await db.query<TradeRow>(
    `SELECT ${TRADE_COLUMNS}
     FROM trades
     WHERE user_id = $1
     ORDER BY created_at DESC, id DESC
     LIMIT $2`,
    [input.userId, input.limit],
  );
  return result.rows.map(mapTrade);
}

export async function loadQuoteRoute(
  client: PoolClient,
  input: { quoteId: string; route: TradeRoute },
): Promise<QuoteRouteRow> {
  const result = await client.query<QuoteRouteRow>(
    `SELECT id, route, fee_bps, fee_minor, payout_minor, total_debit_minor, is_available
     FROM quote_routes
     WHERE quote_id = $1 AND route = $2`,
    [input.quoteId, input.route],
  );
  const row = result.rows[0];
  if (!row || !row.is_available) {
    throw unprocessable(
      'CORRIDOR_UNAVAILABLE',
      'That payout route is not available for this quote',
    );
  }
  return row;
}

/**
 * The recipient rail must exist, be active, serve the receive currency's
 * country, and have the same kind as the chosen route. The mapping lives in
 * reference data, never in the route handler.
 */
export async function resolveRecipientRail(
  client: PoolClient,
  input: { railId: string; receiveCurrency: string; route: TradeRoute },
): Promise<{ id: string; kind: 'mobile_money' | 'bank' }> {
  const result = await client.query<{ id: string; kind: 'mobile_money' | 'bank' }>(
    `SELECT r.id, r.kind
     FROM payout_rails r
     JOIN currencies c ON c.country_code = r.country_code
     WHERE r.id = $1 AND r.active AND c.code = $2 AND c.active`,
    [input.railId, input.receiveCurrency],
  );
  const rail = result.rows[0];
  if (!rail) {
    throw unprocessable(
      'RECIPIENT_REJECTED',
      'The payout rail is not available for the receive currency',
    );
  }
  const expected = input.route === 'p2p' ? 'mobile_money' : 'bank';
  if (rail.kind !== expected) {
    throw unprocessable(
      'RECIPIENT_REJECTED',
      `The ${input.route} route does not accept a ${rail.kind} recipient`,
    );
  }
  return rail;
}

/**
 * Stable trade reference and provider idempotency key for one logical
 * initiation. Repeating the same quote, route and recipient always produces the
 * same reference, so a retry after a rolled-back transaction cannot start a
 * second collection.
 */
export function tradeReferenceFor(input: {
  userId: string;
  quoteId: string;
  route: TradeRoute;
  railId: string;
  accountHash: string;
}): string {
  const digest = createHash('sha256')
    .update(
      [input.userId, input.quoteId, input.route, input.railId, input.accountHash].join(':'),
      'utf8',
    )
    .digest('hex')
    .toUpperCase();
  return `CP-${digest.slice(0, 20)}`;
}

export async function insertTrade(
  client: PoolClient,
  input: {
    reference: string;
    userId: string;
    quoteId: string;
    quoteRouteId: string;
    route: TradeRoute;
    sendCurrency: string;
    receiveCurrency: string;
    sendAmountMinor: bigint;
    feeMinor: bigint;
    feeBps: number;
    receiveAmountMinor: bigint;
    rate: string;
    beneficiaryName: string;
    beneficiaryRailId: string;
    beneficiaryAccountEncrypted: Buffer;
    beneficiaryAccountLast4: string;
    beneficiaryReference: string | null;
  },
): Promise<TradeRow> {
  const result = await client.query<TradeRow>(
    `INSERT INTO trades
       (reference, user_id, quote_id, quote_route_id, route, status,
        send_currency, receive_currency, send_amount_minor, fee_minor, fee_bps,
        receive_amount_minor, rate, beneficiary_name, beneficiary_rail_id,
        beneficiary_account_encrypted, beneficiary_account_last4,
        beneficiary_reference)
     VALUES ($1, $2, $3, $4, $5, 'pending_deposit', $6, $7, $8, $9, $10, $11,
             $12::numeric, $13, $14, $15, $16, $17)
     RETURNING ${TRADE_COLUMNS}`,
    [
      input.reference,
      input.userId,
      input.quoteId,
      input.quoteRouteId,
      input.route,
      input.sendCurrency,
      input.receiveCurrency,
      input.sendAmountMinor.toString(),
      input.feeMinor.toString(),
      input.feeBps,
      input.receiveAmountMinor.toString(),
      input.rate,
      input.beneficiaryName,
      input.beneficiaryRailId,
      input.beneficiaryAccountEncrypted,
      input.beneficiaryAccountLast4,
      input.beneficiaryReference,
    ],
  );
  return result.rows[0] as TradeRow;
}

export async function insertPaymentAttempt(
  client: PoolClient,
  input: {
    tradeId: string;
    provider: string;
    externalReference: string;
    amountMinor: bigint;
    currencyCode: string;
    networkName: string | null;
    pushSent: boolean;
    pushTimeoutSeconds: number;
    pollIntervalSeconds: number;
    status: 'pending' | 'sent';
  },
): Promise<PaymentAttemptRow> {
  const result = await client.query<PaymentAttemptRow>(
    `INSERT INTO payment_attempts
       (trade_id, provider, external_reference, method, amount_minor,
        currency_code, push_sent, network_name, push_timeout_seconds,
        poll_interval_seconds, status)
     VALUES ($1, $2, $3, 'push', $4, $5, $6, $7, $8, $9, $10)
     RETURNING ${ATTEMPT_COLUMNS}`,
    [
      input.tradeId,
      input.provider,
      input.externalReference,
      input.amountMinor.toString(),
      input.currencyCode,
      input.pushSent,
      input.networkName,
      input.pushTimeoutSeconds,
      input.pollIntervalSeconds,
      input.status,
    ],
  );
  return result.rows[0] as PaymentAttemptRow;
}

export async function loadPaymentAttempt(
  client: PoolClient,
  input: { tradeId: string; attemptId?: string | null },
): Promise<PaymentAttemptRow | null> {
  const result = input.attemptId
    ? await client.query<PaymentAttemptRow>(
        `SELECT ${ATTEMPT_COLUMNS}
         FROM payment_attempts
         WHERE id = $1 AND trade_id = $2
         FOR UPDATE`,
        [input.attemptId, input.tradeId],
      )
    : await client.query<PaymentAttemptRow>(
        `SELECT ${ATTEMPT_COLUMNS}
         FROM payment_attempts
         WHERE trade_id = $1
         ORDER BY created_at DESC, id DESC
         LIMIT 1
         FOR UPDATE`,
        [input.tradeId],
      );
  return result.rows[0] ?? null;
}

export async function attachPaymentAttempt(
  client: PoolClient,
  input: { tradeId: string; attemptId: string },
): Promise<void> {
  await client.query(
    `UPDATE trades SET current_payment_attempt_id = $2 WHERE id = $1`,
    [input.tradeId, input.attemptId],
  );
}

async function setActor(client: PoolClient, actor: 'server' | 'provider' | 'user'): Promise<void> {
  await client.query(`SELECT set_config('crosspay.actor', $1, true)`, [actor]);
}

export async function setTradeStatus(
  client: PoolClient,
  input: {
    tradeId: string;
    from: TradeStatus[];
    to: TradeStatus;
    actor: 'server' | 'provider' | 'user';
    failureCode?: string;
  },
): Promise<TradeRow> {
  await setActor(client, input.actor);
  const result = await client.query<TradeRow>(
    `UPDATE trades
     SET status = $2,
         failure_code = COALESCE($4, failure_code),
         completed_at = CASE WHEN $2 IN ('completed', 'failed', 'refunded')
                             THEN now() ELSE completed_at END,
         cancelled_at = CASE WHEN $2 = 'cancelled' THEN now() ELSE cancelled_at END
     WHERE id = $1 AND status = ANY($3::text[])
     RETURNING ${TRADE_COLUMNS}`,
    [input.tradeId, input.to, input.from, input.failureCode ?? null],
  );
  const row = result.rows[0];
  if (!row) {
    throw conflict('TRADE_STATE_INVALID', 'The trade is not in a state that allows this change');
  }
  return row;
}

function providerOutcome(status: string): 'pending' | 'success' | 'failure' {
  const value = status.trim().toUpperCase();
  if (['SUCCESS', 'SUCCEEDED', 'COMPLETED', 'PAID', 'CONFIRMED'].includes(value)) return 'success';
  if (
    ['FAILED', 'FAILURE', 'CANCELLED', 'CANCELED', 'EXPIRED', 'REJECTED', 'REVERSED'].includes(
      value,
    )
  ) {
    return 'failure';
  }
  return 'pending';
}

export async function ledgerAccountId(
  client: PoolClient,
  input: { code: string; currency: string },
): Promise<string> {
  const result = await client.query<{ id: string }>(
    `SELECT id
     FROM ledger_accounts
     WHERE code = $1 AND currency_code = $2 AND active`,
    [`${input.code}-${input.currency}`, input.currency],
  );
  const id = result.rows[0]?.id;
  if (!id) {
    throw new AppError(
      503,
      'LEDGER_NOT_CONFIGURED',
      'The chart of accounts is missing an account needed for this trade',
    );
  }
  return id;
}

export async function postJournalOnce(
  client: PoolClient,
  input: {
    postingKey: string;
    kind: JournalKind;
    currencyCode: string;
    tradeId: string;
    payoutId?: string;
    refundId?: string;
    fxGroupId?: string;
    liquidityProviderId?: string;
    lines: Array<{ accountId: string; amountMinor: bigint }>;
  },
): Promise<void> {
  const existing = await client.query(
    `SELECT id FROM journal_transactions WHERE posting_key = $1`,
    [input.postingKey],
  );
  if (existing.rowCount) return;
  await postJournal(client, {
    postingKey: input.postingKey,
    kind: input.kind,
    currencyCode: input.currencyCode,
    tradeId: input.tradeId,
    payoutId: input.payoutId,
    refundId: input.refundId,
    fxGroupId: input.fxGroupId,
    liquidityProviderId: input.liquidityProviderId,
    lines: input.lines,
  });
}

/**
 * Books the collected money. The PSP withholds its own fee, so CrossPay only
 * ever receives the net amount; fee revenue is the net platform fee, never the
 * gross amount the payer tapped. Principal is a liability to the beneficiary,
 * not revenue.
 *
 * Two single-currency journals keep principal and fee separate:
 * - deposit: cash at the partner + send amount / trade payable - send amount;
 * - fee: cash + net fee / fee revenue - net fee.
 */
async function postCollection(client: PoolClient, trade: TradeRow, pspFeeMinor: bigint): Promise<void> {
  const sendAmount = BigInt(trade.send_amount_minor);
  const platformFee = BigInt(trade.fee_minor);
  const netFee = platformFee - pspFeeMinor;

  const cash = await ledgerAccountId(client, { code: '1000', currency: trade.send_currency });
  const payable = await ledgerAccountId(client, { code: '2000', currency: trade.send_currency });

  await postJournalOnce(client, {
    postingKey: `trade:${trade.id}:deposit`,
    kind: 'deposit_received',
    currencyCode: trade.send_currency,
    tradeId: trade.id,
    lines: [
      { accountId: cash, amountMinor: sendAmount },
      { accountId: payable, amountMinor: -sendAmount },
    ],
  });

  if (netFee !== 0n) {
    const feeRevenue = await ledgerAccountId(client, {
      code: '3000',
      currency: trade.send_currency,
    });
    await postJournalOnce(client, {
      postingKey: `trade:${trade.id}:fee`,
      kind: 'fee_earned',
      currencyCode: trade.send_currency,
      tradeId: trade.id,
      lines: [
        { accountId: cash, amountMinor: netFee },
        { accountId: feeRevenue, amountMinor: -netFee },
      ],
    });
  }
}

export interface CollectionApplication {
  trade: TradeRow;
  outcome: 'pending' | 'escrowed' | 'failed' | 'late_paid' | 'ignored';
}

/**
 * Applies one provider collection snapshot to the trade and attempt. A success
 * posts the deposit and moves the trade to escrowed; a failure moves it to
 * failed; anything else only refreshes the attempt. A provider amount or
 * currency mismatch is a hard contract violation and is never booked.
 */
export async function applyCollectionResult(
  client: PoolClient,
  input: {
    trade: TradeRow;
    attempt: PaymentAttemptRow;
    collection: PaymentCollection;
  },
): Promise<CollectionApplication> {
  const { trade, attempt, collection } = input;
  if (collection.currency !== trade.send_currency) {
    throw new AppError(
      502,
      'PAYMENT_CURRENCY_MISMATCH',
      'The payment provider reported a different currency than the trade',
    );
  }

  const outcome = providerOutcome(collection.status);
  if (outcome === 'pending') {
    if (trade.status !== 'pending_deposit') return { trade, outcome: 'ignored' };
    await client.query(
      `UPDATE payment_attempts
       SET status = 'sent',
           push_sent = true,
           network_name = COALESCE($2, network_name)
       WHERE id = $1 AND status IN ('pending', 'sent')`,
      [attempt.id, collection.provider],
    );
    return { trade, outcome: 'pending' };
  }

  if (outcome === 'failure') {
    if (trade.status !== 'pending_deposit') {
      // A late failure must never tear down a trade whose money already
      // arrived, and a retried webhook must not fail a refunded trade again.
      return { trade, outcome: 'ignored' };
    }
    const failureCode = 'PAYMENT_FAILED';
    await client.query(
      `UPDATE payment_attempts
       SET status = $2, network_name = COALESCE($3, network_name)
       WHERE id = $1`,
      [attempt.id, collection.status.toUpperCase() === 'EXPIRED' ? 'expired' : 'failed', collection.provider],
    );
    const failed = await setTradeStatus(client, {
      tradeId: trade.id,
      from: ['pending_deposit'],
      to: 'failed',
      actor: 'provider',
      failureCode,
    });
    return { trade: failed, outcome: 'failed' };
  }

  if (BigInt(collection.amountMinor) !== BigInt(attempt.amount_minor)) {
    throw new AppError(
      502,
      'PAYMENT_AMOUNT_MISMATCH',
      'The payment provider confirmed a different amount than the trade asked for',
    );
  }

  const pspFee = BigInt(collection.feeMinor ?? 0);
  if (pspFee > BigInt(trade.fee_minor)) {
    throw new AppError(
      502,
      'PSP_FEE_EXCEEDS_PLATFORM_FEE',
      'The payment provider fee is larger than the platform fee',
    );
  }

  await client.query(
    `UPDATE payment_attempts
     SET status = 'confirmed', network_name = COALESCE($2, network_name)
     WHERE id = $1`,
    [attempt.id, collection.provider],
  );

  // The money exists even when the trade was cancelled, expired or failed
  // before the provider callback. Book it exactly once so the refund below has
  // a real ledger entry to reverse; never silently keep an unbooked collection.
  const late = ['cancelled', 'expired', 'failed'].includes(trade.status);
  if (trade.status === 'refunded') return { trade, outcome: 'ignored' };
  await postCollection(client, trade, pspFee);

  if (late) return { trade, outcome: 'late_paid' };

  if (trade.status !== 'pending_deposit') {
    // A retried success callback for an already-escrowed trade is a replay.
    return { trade, outcome: 'escrowed' };
  }

  const escrowed = await setTradeStatus(client, {
    tradeId: trade.id,
    from: ['pending_deposit'],
    to: 'escrowed',
    actor: 'provider',
  });
  return { trade: escrowed, outcome: 'escrowed' };
}

export interface TradeEventView {
  status: TradeStatus;
  at: string;
  noteCode?: string;
}

export async function listTradeEvents(
  db: Pool | PoolClient,
  tradeId: string,
): Promise<TradeEventView[]> {
  const result = await db.query<{ status: TradeStatus; at: Date; note_code: string | null }>(
    `SELECT status, at, note_code
     FROM trade_events
     WHERE trade_id = $1
     ORDER BY at, id`,
    [tradeId],
  );
  return result.rows.map((row) => {
    const event: TradeEventView = {
      status: row.status,
      at: new Date(row.at).toISOString(),
    };
    if (row.note_code !== null) event.noteCode = row.note_code;
    return event;
  });
}
