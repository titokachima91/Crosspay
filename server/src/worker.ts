import type { AppContext } from './http/context.js';
import { markExpiredQuotes } from './quotes.js';
import { refundTrade, startDisbursement } from './payments.js';
import { disburseMatch, tryMatchTrade } from './matching.js';

export interface WorkerReport {
  expiredQuotes: number;
  expiredTrades: number;
  resumedMatches: number;
  resumedPayouts: number;
  retriedRefunds: number;
  errors: Array<{ scope: string; id: string; message: string }>;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * One reconciliation pass. It is deliberately safe to run concurrently with
 * the API: every action is idempotent by posting key, provider reference or
 * refund row. Run it from cron or a long-lived worker process.
 */
export async function runWorkerPass(ctx: AppContext): Promise<WorkerReport> {
  const report: WorkerReport = {
    expiredQuotes: 0,
    expiredTrades: 0,
    resumedMatches: 0,
    resumedPayouts: 0,
    retriedRefunds: 0,
    errors: [],
  };

  report.expiredQuotes = await markExpiredQuotes(ctx.pool).catch((error) => {
    report.errors.push({ scope: 'quotes', id: '-', message: messageOf(error) });
    return 0;
  });

  // Expire funded trades whose match deadline has passed. tryMatchTrade owns
  // the status transition and the refund, so the worker does not duplicate it.
  if (ctx.p2pEnabled) {
    const expired = await ctx.pool.query<{ id: string }>(
      `SELECT id FROM trades
       WHERE route = 'p2p'
         AND status IN ('escrowed', 'matching')
         AND match_deadline_at IS NOT NULL
         AND match_deadline_at <= now()
       ORDER BY match_deadline_at
       LIMIT 50`,
    );
    for (const row of expired.rows) {
      try {
        const attempt = await tryMatchTrade(ctx, { tradeId: row.id });
        if (attempt.expired) report.expiredTrades += 1;
      } catch (error) {
        report.errors.push({ scope: 'trade.expire', id: row.id, message: messageOf(error) });
      }
    }

    // Resume locked matches: a provider callback may have arrived, or a leg may
    // still be pending. A pending provider payout is re-read, never recreated.
    const matches = await ctx.pool.query<{ id: string }>(
      `SELECT id FROM p2p_matches WHERE status = 'locked' ORDER BY matched_at LIMIT 50`,
    );
    for (const row of matches.rows) {
      try {
        const result = await disburseMatch(ctx, { matchId: row.id });
        if (result.match.status !== 'locked') report.resumedMatches += 1;
      } catch (error) {
        report.errors.push({ scope: 'match.resume', id: row.id, message: messageOf(error) });
      }
    }
  }

  // Resume direct-liquidity payouts that a callback may have completed.
  const direct = await ctx.pool.query<{ id: string }>(
    `SELECT t.id
     FROM trades t
     JOIN payouts p ON p.trade_id = t.id
     WHERE t.status IN ('matched', 'disbursing')
       AND p.status IN ('pending', 'submitted')
       AND NOT EXISTS (
         SELECT 1 FROM p2p_matches m
         WHERE m.status = 'locked' AND t.id IN (m.buy_trade_id, m.sell_trade_id)
       )
     ORDER BY p.requested_at
     LIMIT 50`,
  );
  for (const row of direct.rows) {
    try {
      const result = await startDisbursement(ctx, { tradeId: row.id });
      if (['paid', 'failed'].includes(result.payout.status)) report.resumedPayouts += 1;
    } catch (error) {
      report.errors.push({ scope: 'payout.resume', id: row.id, message: messageOf(error) });
    }
  }

  // Retry refunds that were left pending by a provider outage.
  const refunds = await ctx.pool.query<{ trade_id: string; reason_code: string }>(
    `SELECT DISTINCT ON (trade_id) trade_id, reason_code
     FROM refunds
     WHERE status IN ('pending', 'submitted')
     ORDER BY trade_id, created_at DESC
     LIMIT 50`,
  );
  for (const row of refunds.rows) {
    try {
      const result = await refundTrade(ctx, {
        tradeId: row.trade_id,
        reasonCode: row.reason_code,
        allowClosed: true,
      });
      if (result.refund.status === 'paid') report.retriedRefunds += 1;
    } catch (error) {
      report.errors.push({ scope: 'refund.retry', id: row.trade_id, message: messageOf(error) });
    }
  }

  return report;
}
