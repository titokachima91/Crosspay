import type { FastifyRequest } from 'fastify';
import type { z } from 'zod';
import { badRequest } from './errors.js';

export function parseBody<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw badRequest('VALIDATION_FAILED', 'The request body is invalid');
  }
  return result.data;
}

/**
 * Every write uses exactly one key per logical attempt. The server replays the
 * original response for the same key and refuses to reuse it for a different
 * body.
 */
export function requireIdempotencyKey(request: FastifyRequest): string {
  const value = request.headers['x-idempotency-key'];
  if (typeof value !== 'string' || value.length === 0) {
    throw badRequest(
      'IDEMPOTENCY_KEY_REQUIRED',
      'Every write must carry an X-Idempotency-Key header',
    );
  }
  if (value.length > 255) {
    throw badRequest('IDEMPOTENCY_KEY_INVALID', 'The idempotency key is too long');
  }
  return value;
}
