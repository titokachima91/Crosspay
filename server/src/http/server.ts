import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import cors from '@fastify/cors';
import type { AppContext } from './context.js';
import { AppError } from './errors.js';
import { bearerToken, verifyAccessToken } from './auth.js';
import {
  IdempotencyInProgressError,
  IdempotencyKeyReusedError,
} from '../idempotency.js';
import { registerConfigRoutes } from './routes/config.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerMeRoutes } from './routes/me.js';
import { registerBeneficiaryRoutes } from './routes/beneficiaries.js';
import { registerUnavailableRoutes } from './routes/unavailable.js';

const PUBLIC_PATHS = new Set([
  '/health',
  '/api/v1/config',
  '/api/v1/rates',
  '/api/v1/auth/otp/request',
  '/api/v1/auth/otp/verify',
  '/api/v1/auth/refresh',
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

  // Secure by default: a new route requires a token unless it is explicitly
  // listed above. Public routes are the bootstrap and auth surface only.
  app.addHook('onRequest', async (request) => {
    if (request.method === 'OPTIONS') return;
    if (PUBLIC_PATHS.has(requestPath(request.url))) return;

    const token = bearerToken(request);
    const { userId } = await verifyAccessToken(token, ctx.jwtSecret);
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

  await app.register(async (api) => {
    registerConfigRoutes(api, ctx);
    registerAuthRoutes(api, ctx);
    registerMeRoutes(api, ctx);
    registerBeneficiaryRoutes(api, ctx);
    registerUnavailableRoutes(api, ctx);
  }, { prefix: '/api/v1' });

  return app;
}
