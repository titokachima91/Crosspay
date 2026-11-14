import type { PoolClient } from 'pg';

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
