import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import cors from '@fastify/cors';
import type { AppContext } from './context.js';
import { AppError, unauthorized } from './errors.js';
import { bearerToken, verifyAccessToken } from './auth.js';
import {
  IdempotencyInProgressError,
  IdempotencyKeyReusedError,
} from '../idempotency.js';
import { registerConfigRoutes } from './routes/config.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerMeRoutes } from './routes/me.js';
import { registerBeneficiaryRoutes } from './routes/beneficiaries.js';
import { registerPricingRoutes } from './routes/pricing.js';
import { registerTradeRoutes } from './routes/trades.js';
import { registerPaymentRoutes } from './routes/payments.js';
import { registerMatchingRoutes } from './routes/matching.js';
import { registerMarketRoutes } from './routes/market.js';
import { registerInsightRoutes } from './routes/insights.js';
import {
  registerInvoiceRoutes,
  registerPublicInvoiceRoutes,
} from './routes/invoices.js';
import { registerAdminRoutes, adminDashboardHtml } from './routes/admin.js';
import { registerWebhookRoutes } from './routes/webhooks.js';
import { registerUnavailableRoutes } from './routes/unavailable.js';

declare module 'fastify' {
  interface FastifyRequest {
    /** Exact bytes received, needed to verify a provider HMAC. */
    rawBody?: string;
  }
}

const PUBLIC_PATHS = new Set([
  '/health',
  '/api/v1/config',
  '/api/v1/rates',
  '/api/v1/auth/otp/request',
  '/api/v1/auth/otp/verify',
  '/api/v1/auth/refresh',
  '/api/v1/auth/logout',
  '/api/v1/trades/export/download',
  '/admin',
]);

function requestPath(url: string): string {
  return (url.split('?')[0] ?? url).replace(/\/+$/, '') || '/';
}

export async function buildServer(
  ctx: AppContext,
  options: { logger?: FastifyServerOptions['logger']; corsOrigins?: string[] } = {},
): Promise<FastifyInstance> {
  const app = Fastify({
    logger: options.logger ?? false,
    trustProxy: true,
    bodyLimit: 1_048_576,
  });

  if (options.corsOrigins && options.corsOrigins.length > 0) {
    await app.register(cors, {
      origin: options.corsOrigins,
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['Authorization', 'Content-Type', 'X-Idempotency-Key'],
      exposedHeaders: ['Idempotency-Replay', 'Retry-After'],
    });
  }

  app.decorateRequest('userId', undefined);

  // Keep the exact body for provider signatures. Fastify's default parser
  // discards it, and re-serialising JSON would break a byte-exact HMAC.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (request, body, done) => {
    const text = typeof body === 'string' ? body : body.toString('utf8');
    request.rawBody = text;
    if (text.trim().length === 0) {
      done(null, undefined);
      return;
    }
    try {
      done(null, JSON.parse(text) as unknown);
    } catch {
      const error = new Error('Invalid JSON body') as Error & { statusCode: number };
      error.statusCode = 400;
      done(error, undefined);
    }
  });

  // Secure by default: a new route requires a token unless it is explicitly
  // listed above. Public routes are the bootstrap and auth surface only.
  app.addHook('onRequest', async (request) => {
    if (request.method === 'OPTIONS') return;
    const path = requestPath(request.url);
    if (PUBLIC_PATHS.has(path)) return;
    if (path.startsWith('/api/v1/webhooks/payments/')) return;
    if (path.startsWith('/api/v1/invoices/')) return;
    if (path.startsWith('/pay/')) return;
    if (path.startsWith('/api/v1/admin/')) return;

    const token = bearerToken(request);
    const { userId, sessionEpoch } = await verifyAccessToken(token, ctx.jwtSecret);
    const session = await ctx.pool.query<{ auth_epoch: number }>(
      `SELECT auth_epoch FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [userId],
    );
    const currentEpoch = session.rows[0]?.auth_epoch;
    if (currentEpoch === undefined || Number(currentEpoch) !== sessionEpoch) {
      throw unauthorized(
        'SESSION_REVOKED',
        'This session was replaced by a newer sign-in',
      );
    }
    request.userId = userId;
  });

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof AppError) {
      if (error.headers) reply.headers(error.headers);
      reply.code(error.statusCode).send({
        error: { code: error.code, message: error.message },
      });
      return;
    }

    if (error instanceof IdempotencyKeyReusedError) {
      reply.code(409).send({
        error: {
          code: error.code,
          message: 'This idempotency key was already used with a different request',
        },
      });
      return;
    }

    if (error instanceof IdempotencyInProgressError) {
      reply.header('Retry-After', '1');
      reply.code(409).send({
        error: {
          code: error.code,
          message: 'The original request is still in progress; retry shortly',
        },
      });
      return;
    }

    const statusCode =
      typeof (error as { statusCode?: unknown }).statusCode === 'number'
        ? (error as { statusCode: number }).statusCode
        : 500;

    if (statusCode < 500) {
      reply.code(statusCode).send({
        error: {
          code: 'INVALID_REQUEST',
          message: 'The request could not be processed',
        },
      });
      return;
    }

    request.log.error({ err: error }, 'unhandled request error');
    reply.code(500).send({
      error: { code: 'INTERNAL_ERROR', message: 'Unexpected server error' },
    });
  });

  app.setNotFoundHandler((_request, reply) => {
    reply.code(404).send({
      error: { code: 'NOT_FOUND', message: 'Endpoint not found' },
    });
  });

  app.get('/health', async () => {
    await ctx.pool.query('SELECT 1');
    return { status: 'ok', database: 'ok' };
  });

  app.get('/admin', async (_request, reply) => {
    reply.header('content-type', 'text/html; charset=utf-8');
    reply.header('cache-control', 'no-store');
    return reply.send(adminDashboardHtml());
  });

  await app.register(async (api) => {
    registerConfigRoutes(api, ctx);
    registerAuthRoutes(api, ctx);
    registerMeRoutes(api, ctx);
    registerBeneficiaryRoutes(api, ctx);
    registerPricingRoutes(api, ctx);
    registerTradeRoutes(api, ctx);
    registerInvoiceRoutes(api, ctx);
    registerPaymentRoutes(api, ctx);
    registerMatchingRoutes(api, ctx);
    registerMarketRoutes(api, ctx);
    registerInsightRoutes(api, ctx);
    registerAdminRoutes(api, ctx);
    registerWebhookRoutes(api, ctx);
    registerUnavailableRoutes(api, ctx);
  }, { prefix: '/api/v1' });

  registerPublicInvoiceRoutes(app, ctx);

  return app;
}
