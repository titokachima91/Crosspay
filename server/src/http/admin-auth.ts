import { timingSafeEqual } from 'node:crypto';
import type { FastifyRequest } from 'fastify';
import type { AppContext } from './context.js';
import { serviceUnavailable, unauthorized } from './errors.js';

/**
 * Ops authentication is an environment key, not a customer JWT. This is the
 * v1 bridge until the admin identity/role model is built; the key is never
 * logged or returned.
 */
export function requireAdmin(request: FastifyRequest, ctx: AppContext): void {
  if (!ctx.adminApiKey) {
    throw serviceUnavailable('ADMIN_NOT_CONFIGURED', 'The ops dashboard is not configured');
  }
  const value = request.headers['x-admin-key'];
  const provided = typeof value === 'string' ? Buffer.from(value, 'utf8') : null;
  const expected = Buffer.from(ctx.adminApiKey, 'utf8');
  if (!provided || provided.length !== expected.length || !timingSafeEqual(provided, expected)) {
    throw unauthorized('ADMIN_UNAUTHORIZED', 'The admin key is invalid');
  }
}
