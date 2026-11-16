import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context.js';
import { serviceUnavailable } from '../errors.js';

/**
 * Endpoints whose provider or pricing source is not connected yet. They return
 * an honest 503 so the Flutter app can show its "not connected" state instead
 * of receiving invented rates or queue numbers.
 */
export function registerUnavailableRoutes(app: FastifyInstance, _ctx: AppContext): void {
  app.get('/market/depth', async () => {
    throw serviceUnavailable('MARKET_DATA_NOT_CONFIGURED', 'Market depth is not connected yet');
  });

  // Invoice, share, analytics and export still need their own services.
  app.all('/trades/*', async () => {
    throw serviceUnavailable('TRADING_NOT_CONFIGURED', 'Trading is not connected yet');
  });
}
