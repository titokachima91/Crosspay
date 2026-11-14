import type { PoolClient } from 'pg';
import type { AppContext } from '../http/context.js';
import { hashRequest } from '../crypto.js';
import { beginIdempotent, completeIdempotent } from '../idempotency.js';
import { withTransaction } from '../db/pool.js';

export interface IdempotentWorkResult<T> {
  status: number;
  body: T;
  resourceType: string;
  resourceId: string;
}

export interface IdempotentRouteResult<T> {
  status: number;
  body: T;
  replayed: boolean;
}

/**
 * Wraps a write in one database transaction with its idempotency record. The
 * callback must not commit or roll back; the helper owns the transaction.
 */
export async function runIdempotent<T>(
  ctx: AppContext,
  input: {
    userId: string;
    scope: string;
    key: string;
    requestBody: unknown;
  },
  work: (client: PoolClient) => Promise<IdempotentWorkResult<T>>,
): Promise<IdempotentRouteResult<T>> {
  return withTransaction(ctx.pool, async (client) => {
    const outcome = await beginIdempotent(
      client,
      {
        userId: input.userId,
        scope: input.scope,
        key: input.key,
        requestHash: hashRequest(input.requestBody),
        ttlSeconds: ctx.idempotencyTtlSeconds,
      },
      ctx.crypto,
    );

    if (outcome.state === 'replay') {
      return {
        status: outcome.responseStatus,
        body: outcome.responseBody as T,
        replayed: true,
      };
    }

    const result = await work(client);
    await completeIdempotent(
      client,
      {
        id: outcome.id,
        status: 'succeeded',
        responseStatus: result.status,
        responseBody: result.body,
        resourceType: result.resourceType,
        resourceId: result.resourceId,
      },
      ctx.crypto,
    );

    return { status: result.status, body: result.body, replayed: false };
  });
}
