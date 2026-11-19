import { createHash, randomBytes } from 'node:crypto';
import type { Pool, PoolClient } from 'pg';
import type { AppContext } from './http/context.js';
import { AppError, conflict, notFound, serviceUnavailable } from './http/errors.js';
import { withTransaction } from './db/pool.js';

/** Share links live for 72 hours. Only the server extends or replaces one. */
export const INVOICE_TTL_SECONDS = 72 * 60 * 60;

const AVAILABLE_STATUSES = new Set([
  'pending_deposit',
  'escrowed',
  'matching',
  'matched',
  'disbursing',
]);

export interface InvoiceView {
  tradeId: string;
  qrCodeUrl: string;
  shareUrl: string;
  validUntil: string;
  amountMinor: number;
  currency: string;
  verificationHash: string | null;
}

interface InvoiceRow {
  id: string;
  trade_id: string;
  token_hash: string;
  token_encrypted: Buffer;
  amount_minor: string;
  currency_code: string;
  valid_until: Date;
  created_at: Date;
  verification_hash: string | null;
}

export interface PublicInvoiceRow {
  id: string;
  trade_id: string;
  amount_minor: string;
  currency_code: string;
  valid_until: Date;
  created_at: Date;
  reference: string;
  status: string;
  send_amount_minor: string;
  fee_minor: string;
  send_currency: string;
  decimals: number;
}

function newToken(): string {
  return randomBytes(32).toString('base64url');
}

function links(ctx: AppContext, token: string): { qrCodeUrl: string; shareUrl: string } {
  if (!ctx.publicApiUrl) {
    throw serviceUnavailable(
      'INVOICE_NOT_CONFIGURED',
      'Invoice links need a public API URL before they can be issued',
    );
  }
  const base = ctx.publicApiUrl;
  return {
    qrCodeUrl: `${base}/api/v1/invoices/${encodeURIComponent(token)}/qr.png`,
    shareUrl: `${base}/pay/${encodeURIComponent(token)}`,
  };
}

function expired(row: { valid_until: Date }): boolean {
  return new Date(row.valid_until).getTime() <= Date.now();
}

function view(ctx: AppContext, row: InvoiceRow, token: string): InvoiceView {
  const issued = links(ctx, token);
  return {
    tradeId: row.trade_id,
    qrCodeUrl: issued.qrCodeUrl,
    shareUrl: issued.shareUrl,
    validUntil: new Date(row.valid_until).toISOString(),
    amountMinor: Number(row.amount_minor),
    currency: row.currency_code,
    verificationHash: row.verification_hash ?? null,
  };
}

/**
 * Returns the trade's one invoice, creating it on first use and decrypting the
 * stored token on later calls. The caller owns the trade.
 */
export async function loadOrCreateInvoice(
  ctx: AppContext,
  input: { userId: string; tradeId: string },
): Promise<InvoiceView> {
  return withTransaction(ctx.pool, async (client: PoolClient) => {
    const tradeResult = await client.query<{
      id: string;
      status: string;
      send_amount_minor: string;
      fee_minor: string;
      send_currency: string;
    }>(
      `SELECT id, status, send_amount_minor::text, fee_minor::text, send_currency
       FROM trades
       WHERE id = $1 AND user_id = $2
       FOR UPDATE`,
      [input.tradeId, input.userId],
    );
    const trade = tradeResult.rows[0];
    if (!trade) throw notFound('TRADE_NOT_FOUND', 'Trade not found');
    if (!AVAILABLE_STATUSES.has(trade.status)) {
      throw conflict(
        'INVOICE_NOT_AVAILABLE',
        'An invoice is only available while the transfer is still active',
      );
    }

    const existing = await client.query<InvoiceRow>(
      `SELECT i.id, i.trade_id, i.token_hash, i.token_encrypted,
              i.amount_minor::text, i.currency_code, i.valid_until, i.created_at,
              t.verification_hash
       FROM trade_invoices i
       JOIN trades t ON t.id = i.trade_id
       WHERE i.trade_id = $1`,
      [trade.id],
    );
    let row = existing.rows[0];
    let token: string;
    if (row) {
      if (expired(row)) {
        throw new AppError(410, 'INVOICE_EXPIRED', 'This invoice link has expired');
      }
      token = ctx.crypto.decrypt(row.token_encrypted);
    } else {
      token = newToken();
      const created = await client.query<InvoiceRow>(
        `INSERT INTO trade_invoices
           (trade_id, token_hash, token_encrypted, amount_minor, currency_code,
            created_by_user_id, valid_until)
         VALUES ($1, $2, $3, $4::bigint, $5, $6, now() + ($7 * interval '1 second'))
         RETURNING id, trade_id, token_hash, token_encrypted,
                   amount_minor::text, currency_code, valid_until, created_at,
                   (SELECT t.verification_hash FROM trades t
                     WHERE t.id = trade_invoices.trade_id) AS verification_hash`,
        [
          trade.id,
          ctx.crypto.hashToken(token),
          ctx.crypto.encrypt(token),
          (BigInt(trade.send_amount_minor) + BigInt(trade.fee_minor)).toString(),
          trade.send_currency,
          input.userId,
          INVOICE_TTL_SECONDS,
        ],
      );
      row = created.rows[0]!;
    }
    return view(ctx, row, token);
  });
}

export async function loadInvoiceByToken(
  pool: Pool,
  token: string,
): Promise<PublicInvoiceRow | null> {
  if (token.length < 16 || token.length > 200) return null;
  const result = await pool.query<PublicInvoiceRow>(
    `SELECT i.id, i.trade_id, i.amount_minor::text, i.currency_code,
            i.valid_until, i.created_at, t.reference, t.status,
            t.send_amount_minor::text, t.fee_minor::text, t.send_currency,
            c.decimals
     FROM trade_invoices i
     JOIN trades t ON t.id = i.trade_id
     JOIN currencies c ON c.code = i.currency_code
     WHERE i.token_hash = $1`,
    [sha256(token)],
  );
  return result.rows[0] ?? null;
}

export function invoiceIsExpired(row: { valid_until: Date }): boolean {
  return expired(row);
}

function sha256(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}
