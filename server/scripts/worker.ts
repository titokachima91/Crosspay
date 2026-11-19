import { startWorkerService } from '../src/worker-cli.js';

/**
 * Development entrypoint. The compiled production entrypoint is
 * `node dist/worker-main.js`.
 */
await startWorkerService();
