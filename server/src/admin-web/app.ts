import path from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
import multipart from '@fastify/multipart';
import fastifyStatic from '@fastify/static';
import view from '@fastify/view';
import ejs from 'ejs';
import type { AppContext } from '../http/context.js';
import type { AdminWebConfig } from './config.js';
import { registerAdminWebRoutes } from './routes.js';
import { ActivityStream } from './activity.js';

export async function buildAdminWebServer(
  ctx: AppContext,
  config: AdminWebConfig,
): Promise<FastifyInstance> {
  const app = Fastify({
    logger: false,
    trustProxy: true,
    bodyLimit: 1_048_576,
  });

  await app.register(cookie);
  await app.register(formbody);
  await app.register(multipart, {
    limits: { fileSize: 2 * 1024 * 1024, files: 1, fields: 20 },
  });
  await app.register(fastifyStatic, {
    root: path.join(import.meta.dirname, 'public'),
    prefix: '/assets/',
  });
  await app.register(view, {
    engine: { ejs },
    root: path.join(import.meta.dirname, 'views'),
    viewExt: 'ejs',
  });

  app.addHook('onSend', async (_request, reply, payload) => {
    reply.header('x-frame-options', 'DENY');
    reply.header('x-content-type-options', 'nosniff');
    reply.header('referrer-policy', 'no-referrer');
    reply.header('x-robots-tag', 'noindex, nofollow');
    reply.header(
      'content-security-policy',
      "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    );
    if (config.cookieSecure) {
      reply.header('strict-transport-security', 'max-age=31536000; includeSubDomains');
    }
    if (typeof payload === 'string' && reply.getHeader('content-type')?.toString().startsWith('text/html')) {
      reply.header('cache-control', 'no-store');
    }
    return payload;
  });

  const activity = new ActivityStream(ctx.pool);
  registerAdminWebRoutes(app, ctx, config, activity);
  app.addHook('onClose', async () => {
    activity.stop();
  });
  return app;
}
