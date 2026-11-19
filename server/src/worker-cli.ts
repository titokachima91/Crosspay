import { buildRuntime, positiveInt } from './runtime.js';
import { runWorkerPass } from './worker.js';

/**
 * Reconciliation worker service. Run it continuously in production, or once
 * from cron / a deployment job with WORKER_ONCE=true.
 */
export async function startWorkerService(): Promise<void> {
  const runtime = buildRuntime();
  const intervalMs = positiveInt('WORKER_INTERVAL_SECONDS', 30) * 1_000;
  const runOnce = (process.env['WORKER_ONCE'] ?? 'false').trim().toLowerCase() === 'true';
  let stopping = false;

  async function pass(): Promise<void> {
    try {
      const report = await runWorkerPass(runtime.ctx);
      console.log(JSON.stringify({ at: new Date().toISOString(), ...report }));
    } catch (error) {
      console.error(
        JSON.stringify({
          at: new Date().toISOString(),
          error: error instanceof Error ? error.message : String(error),
        }),
      );
    }
  }

  if (runOnce) {
    await pass();
    await runtime.pool.end();
    process.exit(0);
  }

  await pass();
  const timer = setInterval(() => {
    if (!stopping) void pass();
  }, intervalMs);

  async function shutdown(signal: string): Promise<void> {
    stopping = true;
    clearInterval(timer);
    console.log(JSON.stringify({ at: new Date().toISOString(), signal, stopping: true }));
    await runtime.pool.end();
    process.exit(0);
  }

  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
}
