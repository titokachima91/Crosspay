import { buildRuntime } from '../runtime.js';
import { buildAdminWebServer } from './app.js';
import { loadAdminWebConfig } from './config.js';

const runtime = buildRuntime();
const config = loadAdminWebConfig();
const app = await buildAdminWebServer(runtime.ctx, config);

await app.listen({ port: config.port, host: config.host });
console.log(`CrossPay admin portal on ${config.baseUrl}`);

async function shutdown(signal: string): Promise<void> {
  console.log(`admin-web ${signal}, shutting down`);
  await app.close();
  await runtime.pool.end();
  process.exit(0);
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
