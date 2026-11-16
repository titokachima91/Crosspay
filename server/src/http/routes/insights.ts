import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireUserId, signExportToken, verifyExportToken } from '../auth.js';
import { conflict, serviceUnavailable } from '../errors.js';
import { parseBody } from '../validation.js';

const exportQuerySchema = z.object({ token: z.string().min(1) });

interface AnalyticsRow {
  receive_currency: string;
  trades: string;
  sent_minor: string;
  received_minor: string;
}

interface ExportRow {
  reference: string;
  created_at: Date;
  status: string;
  route: string;
  send_currency: string;
  send_amount_minor: string;
  fee_minor: string;
  receive_currency: string;
  receive_amount_minor: string;
  rate: string;
  beneficiary_name: string;
}

function csvCell(value: string | number): string {
  const text = String(value);
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

/**
 * Server-calculated analytics and a server-built CSV export. The app never
 * aggregates or builds the file.
 */
export function registerInsightRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/trades/analytics', async (request) => {
    const userId = requireUserId(request);
    const profile = await ctx.pool.query<{ limit_currency_code: string | null }>(
      `SELECT limit_currency_code FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [userId],
    );
    const sendCurrency = profile.rows[0]?.limit_currency_code;
    if (!sendCurrency) {
      throw conflict('PROFILE_INCOMPLETE', 'Finish the KYC step before viewing analytics');
    }

    const rows = await ctx.pool.query<AnalyticsRow>(
      `SELECT receive_currency,
              count(*)::text AS trades,
              sum(send_amount_minor)::text AS sent_minor,
              sum(receive_amount_minor)::text AS received_minor
       FROM trades
       WHERE user_id = $1 AND status = 'completed' AND send_currency = $2
       GROUP BY receive_currency
       ORDER BY receive_currency`,
      [userId, sendCurrency],
    );

    // The contract has one sent currency and one received currency. Use the
    // user's primary send currency and the highest-volume receive currency;
    // never add minor units across currencies.
    const primary = [...rows.rows].sort((left, right) => {
      const byCount = Number(right.trades) - Number(left.trades);
      return byCount !== 0 ? byCount : left.receive_currency.localeCompare(right.receive_currency);
    })[0];

    return {
      totals: {
        trades: primary ? Number(primary.trades) : 0,
        sentMinor: primary ? Number(primary.sent_minor) : 0,
        sentCurrency: sendCurrency,
        receivedMinor: primary ? Number(primary.received_minor) : 0,
        receivedCurrency: primary?.receive_currency ?? sendCurrency,
      },
      corridors: rows.rows.map((row) => ({
        from: sendCurrency,
        to: row.receive_currency,
        trades: Number(row.trades),
        sentMinor: Number(row.sent_minor),
      })),
    };
  });

  app.get('/trades/export', async (request) => {
    const userId = requireUserId(request);
    if (!ctx.publicApiUrl) {
      throw serviceUnavailable(
        'EXPORT_NOT_CONFIGURED',
        'CSV export needs a public API URL before it can issue a link',
      );
    }
    const now = new Date();
    const token = await signExportToken({ userId, secret: ctx.jwtSecret, now });
    return {
      downloadUrl: `${ctx.publicApiUrl}/api/v1/trades/export/download?token=${encodeURIComponent(token)}`,
      expiresAt: new Date(now.getTime() + 5 * 60 * 1_000).toISOString(),
    };
  });

  app.get('/trades/export/download', async (request, reply) => {
    const { token } = parseBody(exportQuerySchema, request.query);
    const { userId } = await verifyExportToken(token, ctx.jwtSecret);

    const rows = await ctx.pool.query<ExportRow>(
      `SELECT reference, created_at, status, route, send_currency,
              send_amount_minor, fee_minor, receive_currency,
              receive_amount_minor, rate, beneficiary_name
       FROM trades
       WHERE user_id = $1
       ORDER BY created_at DESC, id DESC
       LIMIT 10000`,
      [userId],
    );

    const header = [
      'reference',
      'created_at',
      'status',
      'route',
      'send_currency',
      'send_amount_minor',
      'fee_minor',
      'receive_currency',
      'receive_amount_minor',
      'rate',
      'beneficiary_name',
    ];
    const lines = [header.join(',')];
    for (const row of rows.rows) {
      lines.push(
        [
          row.reference,
          new Date(row.created_at).toISOString(),
          row.status,
          row.route,
          row.send_currency,
          row.send_amount_minor,
          row.fee_minor,
          row.receive_currency,
          row.receive_amount_minor,
          row.rate,
          row.beneficiary_name,
        ]
          .map(csvCell)
          .join(','),
      );
    }

    reply.header('content-type', 'text/csv; charset=utf-8');
    reply.header('content-disposition', 'attachment; filename="crosspay-trades.csv"');
    reply.header('cache-control', 'no-store');
    return reply.send(`${lines.join('\n')}\n`);
  });
}
