import type { Pool, PoolClient } from 'pg';
import { withTransaction } from './db/pool.js';
import type { PricingRoute } from './providers/pricing.js';

export interface QuoteRow {
  id: string;
  user_id: string;
  send_currency: string;
  receive_currency: string;
  send_amount_minor: string;
  rate: string;
  quoted_at: Date;
  expires_at: Date;
  status: 'active' | 'consumed' | 'expired' | 'cancelled';
  consumed_at: Date | null;
}

export class QuoteNotFoundError extends Error {
  readonly code = 'QUOTE_NOT_FOUND';
  constructor() {
    super('Quote does not exist or belongs to another user');
    this.name = 'QuoteNotFoundError';
  }
}

export class QuoteExpiredError extends Error {
  readonly code = 'QUOTE_EXPIRED';
  constructor() {
    super('The rate lock has expired; request a new quote');
    this.name = 'QuoteExpiredError';
  }
}

export class QuoteNotActiveError extends Error {
  readonly code = 'QUOTE_NOT_ACTIVE';
  constructor(readonly status: string) {
    super(`Quote is ${status}, not active`);
    this.name = 'QuoteNotActiveError';
  }
}

function mapQuote(row: Record<string, unknown>): QuoteRow {
  return {
    id: String(row['id']),
    user_id: String(row['user_id']),
    send_currency: String(row['send_currency']),
    receive_currency: String(row['receive_currency']),
    send_amount_minor: String(row['send_amount_minor']),
    rate: String(row['rate']),
    quoted_at: row['quoted_at'] as Date,
    expires_at: row['expires_at'] as Date,
    status: row['status'] as QuoteRow['status'],
    consumed_at: row['consumed_at'] === null ? null : (row['consumed_at'] as Date),
  };
}

const QUOTE_COLUMNS = `id, user_id, send_currency, receive_currency, send_amount_minor,
                       rate, quoted_at, expires_at, status, consumed_at`;

/**
 * Locks and consumes a quote for one trade. Call this inside the same
 * transaction that inserts the trade: a quote can never be consumed twice.
 */
export async function consumeQuote(
  client: PoolClient,
  input: { quoteId: string; userId: string; now?: Date },
): Promise<QuoteRow> {
  const now = input.now ?? new Date();
  const selected = await client.query(
    `SELECT ${QUOTE_COLUMNS}
     FROM quotes
     WHERE id = $1 AND user_id = $2
     FOR UPDATE`,
    [input.quoteId, input.userId],
  );

  const row = selected.rows[0];
  if (!row) throw new QuoteNotFoundError();

  const quote = mapQuote(row);
  if (quote.status !== 'active') throw new QuoteNotActiveError(quote.status);
  if (quote.expires_at.getTime() <= now.getTime()) throw new QuoteExpiredError();

  const updated = await client.query(
    `UPDATE quotes
     SET status = 'consumed', consumed_at = $3
     WHERE id = $1 AND user_id = $2 AND status = 'active'
     RETURNING ${QUOTE_COLUMNS}`,
    [input.quoteId, input.userId, now],
  );

  const consumed = updated.rows[0];
  if (!consumed) throw new QuoteNotActiveError('consumed');
  return mapQuote(consumed);
}

/** Worker helper: marks expired active quotes without touching consumed history. */
export async function markExpiredQuotes(
  client: PoolClient,
  now = new Date(),
): Promise<number> {
  const result = await client.query(
    `UPDATE quotes
     SET status = 'expired'
     WHERE status = 'active' AND expires_at <= $1`,
    [now],
  );
  return result.rowCount ?? 0;
}

export interface NewQuote {
  userId: string;
  sendCurrency: string;
  receiveCurrency: string;
  sendAmountMinor: bigint;
  rate: number;
  quotedAt: Date;
  expiresAt: Date;
  routes: PricingRoute[];
}

export interface StoredQuote {
  id: string;
  rate: number;
  serverTime: string;
  expiresAt: string;
  routes: PricingRoute[];
}

/** Raised when a provider response cannot be stored without breaking an invariant. */
export class QuotePricingInvalidError extends Error {
  readonly code = 'PRICING_INVALID';
  constructor(message: string) {
    super(message);
    this.name = 'QuotePricingInvalidError';
  }
}

function assertQuotePricing(input: NewQuote): void {
  if (input.sendAmountMinor <= 0n) {
    throw new QuotePricingInvalidError('The send amount must be positive');
  }
  if (!Number.isFinite(input.rate) || input.rate <= 0) {
    throw new QuotePricingInvalidError('The provider rate is not positive');
  }
  if (
    Number.isNaN(input.quotedAt.getTime()) ||
    Number.isNaN(input.expiresAt.getTime()) ||
    input.expiresAt.getTime() <= input.quotedAt.getTime()
  ) {
    throw new QuotePricingInvalidError('The provider quote window is invalid');
  }

  const seen = new Set<string>();
  let recommended = 0;
  for (const route of input.routes) {
    if (seen.has(route.route)) {
      throw new QuotePricingInvalidError(`The provider returned ${route.route} twice`);
    }
    seen.add(route.route);
    if (route.estimatedMaxSeconds < route.estimatedMinSeconds) {
      throw new QuotePricingInvalidError('The provider estimate is out of order');
    }
    if (route.totalDebitMinor !== Number(input.sendAmountMinor) + route.feeMinor) {
      throw new QuotePricingInvalidError('The provider total debit does not cover the fee');
    }
    if (route.isRecommended) {
      recommended += 1;
      if (!route.isAvailable) {
        throw new QuotePricingInvalidError('An unavailable route cannot be recommended');
      }
    }
  }
  if (recommended > 1) {
    throw new QuotePricingInvalidError('The provider recommended more than one route');
  }
}

/**
 * Persists the priced quote in one transaction. The provider owns the price;
 * this function owns the durable promise and the route snapshot.
 */
export async function createQuote(pool: Pool, input: NewQuote): Promise<StoredQuote> {
  assertQuotePricing(input);

  return withTransaction(pool, async (client) => {
    const inserted = await client.query(
      `INSERT INTO quotes
         (user_id, send_currency, receive_currency, send_amount_minor,
          rate, quoted_at, expires_at)
       VALUES ($1, $2, $3, $4, $5::numeric, $6, $7)
       RETURNING id`,
      [
        input.userId,
        input.sendCurrency,
        input.receiveCurrency,
        input.sendAmountMinor.toString(),
        input.rate.toFixed(10),
        input.quotedAt,
        input.expiresAt,
      ],
    );
    const quoteId = String(inserted.rows[0]?.['id']);

    for (const route of input.routes) {
      await client.query(
        `INSERT INTO quote_routes
           (quote_id, route, fee_bps, fee_minor, payout_minor, total_debit_minor,
            estimated_min_seconds, estimated_max_seconds, is_recommended,
            is_available, matching_density_percent, status_code, status_level,
            safeguard_code, fee_breakdown)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::jsonb)`,
        [
          quoteId,
          route.route,
          route.feeBps,
          route.feeMinor,
          route.payoutMinor,
          route.totalDebitMinor,
          route.estimatedMinSeconds,
          route.estimatedMaxSeconds,
          route.isRecommended,
          route.isAvailable,
          route.matchingDensityPercent ?? null,
          route.status?.code ?? null,
          route.status?.level ?? null,
          route.safeguardCode ?? null,
          JSON.stringify(route.breakdown),
        ],
      );
    }

    return {
      id: quoteId,
      rate: input.rate,
      serverTime: input.quotedAt.toISOString(),
      expiresAt: input.expiresAt.toISOString(),
      routes: input.routes,
    };
  });
}
