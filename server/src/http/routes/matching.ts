import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireUserId } from '../auth.js';
import { parseBody, requireIdempotencyKey } from '../validation.js';
import { runIdempotent } from '../idempotent-route.js';
import {
  disburseMatch,
  tryMatchTrade,
  type MatchAttempt,
  type MatchDisbursement,
} from '../../matching.js';

const idSchema = z.object({ id: z.string().uuid() });

export function registerMatchingRoutes(app: FastifyInstance, ctx: AppContext): void {
  /**
   * Tries to match one funded trade. The worker will call the same service for
   * every escrowed trade; the route exists so an operator or a test can run
   * one deterministic attempt. No counterparty identity is returned.
   */
  app.post('/trades/:id/match', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<MatchAttempt>(
      ctx,
      { userId, scope: 'trade.match', key, requestBody: { id } },
      async () => {
        const attempt = await tryMatchTrade(ctx, { tradeId: id, userId });
        return {
          status: attempt.matched || attempt.expired ? 200 : 202,
          body: attempt,
          resourceType: attempt.match ? 'p2p_match' : 'trade',
          resourceId: attempt.match?.id ?? id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });

  /** Pays both legs of a locked match. Safe to retry after a provider outage. */
  app.post('/matches/:id/disburse', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<MatchDisbursement>(
      ctx,
      { userId, scope: 'match.disburse', key, requestBody: { id } },
      async () => {
        const disbursed = await disburseMatch(ctx, { matchId: id, userId });
        return {
          status: 200,
          body: disbursed,
          resourceType: 'p2p_match',
          resourceId: id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });
}
