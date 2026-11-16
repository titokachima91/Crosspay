import { buildRuntime } from '../runtime.js';
import { buildServer } from './server.js';

const runtime = buildRuntime();

const app = await buildServer(runtime.ctx, {
  logger: runtime.logger,
  corsOrigins: runtime.corsOrigins,
});

await app.listen({ port: runtime.port, host: runtime.host });

async function shutdown(signal: string): Promise<void> {
  app.log.info({ signal }, 'shutting down');
  await app.close();
  await runtime.pool.end();
  process.exit(0);
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
