import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context.js';
import { requireUserId } from '../auth.js';

interface DepthRow {
  send_currency: string;
  receive_currency: string;
  estimated_settle_seconds: number;
  queue_depth: string;
}

/**
 * Real queue depth from funded P2P trades. A corridor is shown only when an
 * operator set both `enabled` and `estimated_settle_seconds`; the server never
 * invents liquidity or a wait time.
 */
export function registerMarketRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/market/depth', async (request) => {
    requireUserId(request);
    const result = await ctx.pool.query<DepthRow>(
      `SELECT c.send_currency,
              c.receive_currency,
              c.estimated_settle_seconds,
              count(t.id)::text AS queue_depth
       FROM p2p_corridors c
       LEFT JOIN trades t
         ON t.send_currency = c.send_currency
        AND t.receive_currency = c.receive_currency
        AND t.status IN ('escrowed', 'matching')
       WHERE c.enabled
         AND c.estimated_settle_seconds IS NOT NULL
       GROUP BY c.send_currency, c.receive_currency, c.estimated_settle_seconds
       ORDER BY c.send_currency, c.receive_currency`,
    );
    return {
      corridors: result.rows.map((row) => ({
        from: row.send_currency,
        to: row.receive_currency,
        queueDepth: Number(row.queue_depth),
        estimatedSettleSeconds: row.estimated_settle_seconds,
      })),
    };
  });
}
