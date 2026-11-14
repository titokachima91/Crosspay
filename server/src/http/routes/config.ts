import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context.js';
import { loadAppConfig } from '../../repositories/config-repository.js';

export function registerConfigRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/config', async () => loadAppConfig(ctx.pool));
}
