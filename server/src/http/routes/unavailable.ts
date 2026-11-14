import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context.js';
import { serviceUnavailable } from '../errors.js';

/**
 * Endpoints whose provider or pricing source is not connected yet. They return
 * an honest 503 so the Flutter app can show its "not connected" state instead
 * of receiving invented rates or queue numbers.
 */
export function registerUnavailableRoutes(app: FastifyInstance, _ctx: AppContext): void {
  app.get('/rates', async () => {
    throw serviceUnavailable('PRICING_NOT_CONFIGURED', 'Live rates are not connected yet');
  });

  app.get('/market/depth', async () => {
    throw serviceUnavailable('MARKET_DATA_NOT_CONFIGURED', 'Market depth is not connected yet');
  });

  app.get('/trade/estimate', async () => {
    throw serviceUnavailable('PRICING_NOT_CONFIGURED', 'Live pricing is not connected yet');
  });

  app.post('/trade/quote', async () => {
    throw serviceUnavailable('PRICING_NOT_CONFIGURED', 'Live pricing is not connected yet');
  });

  app.post('/trade/initiate', async () => {
    throw serviceUnavailable('PRICING_NOT_CONFIGURED', 'Live pricing is not connected yet');
  });

  app.get('/trades', async () => {
    throw serviceUnavailable('TRADING_NOT_CONFIGURED', 'Trading is not connected yet');
  });

  app.all('/trades/*', async () => {
    throw serviceUnavailable('TRADING_NOT_CONFIGURED', 'Trading is not connected yet');
  });
}
