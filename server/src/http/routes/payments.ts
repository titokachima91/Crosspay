import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireUserId } from '../auth.js';
import { parseBody, requireIdempotencyKey } from '../validation.js';
import { runIdempotent } from '../idempotent-route.js';
import {
  refundTrade,
  startDisbursement,
  type DisbursementResult,
  type RefundView,
} from '../../payments.js';
import type { TradeView } from '../../trades.js';

const idSchema = z.object({ id: z.string().uuid() });
const refundSchema = z.object({
  reason: z
    .string()
    .trim()
    .regex(/^[a-z][a-z0-9_]{1,63}$/)
    .optional(),
});

function statusFor(result: DisbursementResult): number {
  return result.payout.status === 'paid' || result.payout.status === 'failed' ? 200 : 202;
}

export function registerPaymentRoutes(app: FastifyInstance, ctx: AppContext): void {
  /**
   * Starts or resumes the payout for an escrowed trade. The app does not need
   * to call this when the matching engine pays automatically; it exists so an
   * interrupted payout can be resumed and so bank/direct liquidity routes have
   * an explicit trigger.
   */
  app.post('/trades/:id/disburse', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<DisbursementResult>(
      ctx,
      { userId, scope: 'trade.disburse', key, requestBody: { id } },
      async () => {
        const disbursed = await startDisbursement(ctx, { userId, tradeId: id });
        return {
          status: statusFor(disbursed),
          body: disbursed,
          resourceType: 'trade',
          resourceId: id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });

  /**
   * Refunds a confirmed collection in full. The provider must confirm before a
   * single ledger line is reversed; a failed provider call leaves the trade
   * escrowed and retryable.
   */
  app.post('/trades/:id/refund', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);
    const body = parseBody(refundSchema, request.body ?? {});

    const result = await runIdempotent<{ trade: TradeView; refund: RefundView }>(
      ctx,
      {
        userId,
        scope: 'trade.refund',
        key,
        requestBody: { id, reason: body.reason ?? null },
      },
      async () => {
        const refunded = await refundTrade(ctx, {
          userId,
          tradeId: id,
          reasonCode: body.reason ?? 'customer_request',
          allowClosed: false,
        });
        return {
          status: 200,
          body: refunded,
          resourceType: 'trade',
          resourceId: id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });
}
