import type { FastifyInstance } from 'fastify';
import QRCode from 'qrcode';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireUserId } from '../auth.js';
import { AppError } from '../errors.js';
import { parseBody, requireIdempotencyKey } from '../validation.js';
import { runIdempotent } from '../idempotent-route.js';
import {
  invoiceIsExpired,
  loadInvoiceByToken,
  loadOrCreateInvoice,
  type PublicInvoiceRow,
} from '../../invoices.js';

const idSchema = z.object({ id: z.string().uuid() });
const tokenSchema = z.object({ token: z.string().min(16).max(200) });

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatAmount(row: { amount_minor: string; decimals: number }): string {
  const decimals = Number(row.decimals);
  const raw = BigInt(row.amount_minor);
  const scale = 10n ** BigInt(decimals);
  const whole = raw / scale;
  const fraction = raw % scale;
  const grouped = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  if (decimals === 0) return grouped;
  return `${grouped}.${fraction.toString().padStart(decimals, '0')}`;
}

function payPage(row: PublicInvoiceRow, expired: boolean): string {
  const amount = formatAmount(row);
  const status = expired ? 'Expired' : row.status.replace(/_/g, ' ');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>CrossPay invoice ${escapeHtml(row.reference)}</title>
<style>
:root { color-scheme: light; }
body { margin:0; min-height:100vh; display:grid; place-items:center; background:#f5f6fa; color:#1b1b1f; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
main { width:min(92vw,420px); background:#fff; border:1px solid #d0d3db; border-radius:18px; padding:28px; box-sizing:border-box; }
.brand { font-size:13px; letter-spacing:.12em; text-transform:uppercase; color:#1a237e; font-weight:700; }
h1 { font-size:20px; margin:18px 0 4px; }
.amount { font-size:36px; font-weight:700; margin:10px 0 2px; }
.sub { color:#5f6368; font-size:14px; }
.row { display:flex; justify-content:space-between; gap:16px; padding:14px 0; border-top:1px solid #eceef4; font-size:14px; }
.row span:last-child { text-align:right; font-weight:600; }
.pill { display:inline-block; padding:4px 10px; border-radius:999px; font-size:12px; font-weight:600; background:${expired ? '#fdecea' : '#e8f5e9'}; color:${expired ? '#b3261e' : '#1b5e20'}; text-transform:capitalize; }
.note { margin-top:18px; padding:14px; border-radius:12px; background:${expired ? '#fdecea' : '#eef2ff'}; color:${expired ? '#8c1d18' : '#1a237e'}; font-size:13px; line-height:1.5; }
</style>
</head>
<body>
<main>
  <div class="brand">CrossPay</div>
  <h1>Transfer invoice</h1>
  <div class="sub">Reference ${escapeHtml(row.reference)}</div>
  <div class="amount">${escapeHtml(amount)} ${escapeHtml(row.currency_code)}</div>
  <div class="sub">Amount due</div>
  <div class="row"><span>Status</span><span class="pill">${escapeHtml(status)}</span></div>
  <div class="row"><span>Valid until</span><span>${escapeHtml(new Date(row.valid_until).toISOString().slice(0, 16).replace('T', ' '))} UTC</span></div>
  <div class="note">${
    expired
      ? 'This invoice has expired. Ask the sender for a new link.'
      : 'Pay in the CrossPay app or with your mobile-money provider using this reference. CrossPay never asks for your PIN or a payment to a personal account.'
  }</div>
</main>
</body>
</html>`;
}

/**
 * Public payer page and QR image. Neither route exposes the customer's phone,
 * beneficiary, ledger or payment-attempt data.
 */
export function registerPublicInvoiceRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/pay/:token', async (request, reply) => {
    const { token } = parseBody(tokenSchema, request.params);
    const row = await loadInvoiceByToken(ctx.pool, token);
    if (!row) {
      return reply.code(404).type('text/html; charset=utf-8').send(payPage({
        id: '',
        trade_id: '',
        amount_minor: '0',
        currency_code: '',
        valid_until: new Date(),
        created_at: new Date(),
        reference: 'unknown',
        status: 'not_found',
        send_amount_minor: '0',
        fee_minor: '0',
        send_currency: '',
        decimals: 0,
      }, true));
    }
    reply
      .header('cache-control', 'no-store')
      .header('x-robots-tag', 'noindex, nofollow')
      .header('x-frame-options', 'DENY')
      .header('x-content-type-options', 'nosniff')
      .header(
        'content-security-policy',
        "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      );
    return reply.type('text/html; charset=utf-8').send(payPage(row, invoiceIsExpired(row)));
  });

  app.get('/api/v1/invoices/:token/qr.png', async (request, reply) => {
    const { token } = parseBody(tokenSchema, request.params);
    const row = await loadInvoiceByToken(ctx.pool, token);
    if (!row) throw new AppError(404, 'INVOICE_NOT_FOUND', 'Invoice not found');
    if (invoiceIsExpired(row)) {
      throw new AppError(410, 'INVOICE_EXPIRED', 'This invoice link has expired');
    }
    if (!ctx.publicApiUrl) {
      throw new AppError(503, 'INVOICE_NOT_CONFIGURED', 'Invoice links are not configured');
    }
    const shareUrl = `${ctx.publicApiUrl}/pay/${encodeURIComponent(token)}`;
    const png = await QRCode.toBuffer(shareUrl, {
      type: 'png',
      width: 512,
      margin: 2,
      errorCorrectionLevel: 'M',
    });
    return reply
      .header('content-type', 'image/png')
      .header('cache-control', 'private, max-age=300')
      .header('x-content-type-options', 'nosniff')
      .send(png);
  });
}

/** Authenticated invoice endpoints. */
export function registerInvoiceRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/trades/:id/invoice', async (request) => {
    const userId = requireUserId(request);
    const { id } = parseBody(idSchema, request.params);
    const invoice = await loadOrCreateInvoice(ctx, { userId, tradeId: id });
    const { verificationHash: _verificationHash, ...payload } = invoice;
    return payload;
  });

  app.post('/trades/:id/share', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);
    const invoice = await loadOrCreateInvoice(ctx, { userId, tradeId: id });

    const result = await runIdempotent<{
      shareUrl: string;
      validUntil: string;
      verificationHash: string | null;
    }>(
      ctx,
      { userId, scope: 'trade.share', key, requestBody: { id } },
      async () => ({
        status: 200,
        body: {
          shareUrl: invoice.shareUrl,
          validUntil: invoice.validUntil,
          verificationHash: invoice.verificationHash,
        },
        resourceType: 'trade',
        resourceId: id,
      }),
    );
    reply.code(result.status);
    return result.body;
  });
}
