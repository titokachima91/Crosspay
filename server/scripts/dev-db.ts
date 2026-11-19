import 'dotenv/config';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import EmbeddedPostgres from 'embedded-postgres';
import { Pool } from 'pg';
import { runMigrations } from '../src/db/migrate.js';
import { runSeed } from '../src/db/seed.js';

/**
 * A persistent local PostgreSQL cluster for hands-on development, powered by
 * the same embedded binary the test suite uses. No Docker or system Postgres
 * is required.
 *
 *   npm run dev:db            start (and migrate/seed) on port 55432
 *   npm run dev:db -- --reset delete the cluster and start from scratch
 *
 * The data directory is `server/.devdb` and is gitignored. The process keeps
 * running until Ctrl-C so `npm run admin:dev` and `npm run dev` can share it.
 */
const DATA_DIR = path.resolve('.devdb');
const PORT = Number(process.env['DEV_DB_PORT'] ?? 55432);
const USER = 'postgres';
const PASSWORD = 'postgres';
const DATABASE = 'postgres';

async function main(): Promise<void> {
  const reset = process.argv.includes('--reset');
  if (reset) {
    const { rm } = await import('node:fs/promises');
    await rm(DATA_DIR, { recursive: true, force: true });
    console.log('dev:db removed the previous cluster');
  }

  const existing = await readFile(path.join(DATA_DIR, 'PG_VERSION'), 'utf8').catch(() => null);
  const persistent = true;
  const embedded = new EmbeddedPostgres({
    databaseDir: DATA_DIR,
    port: PORT,
    user: USER,
    password: PASSWORD,
    persistent,
    autoRehydrateSymlinks: true,
    onLog: () => undefined,
    onError: (error: unknown) => console.error('dev:db postgres error', error),
  });

  await mkdir(DATA_DIR, { recursive: true });
  if (!existing) {
    console.log('dev:db initialising a new cluster');
    await embedded.initialise();
  }
  await embedded.start();

  const pool = new Pool({
    host: '127.0.0.1',
    port: PORT,
    user: USER,
    password: PASSWORD,
    database: DATABASE,
    max: 4,
  });
  try {
    const migration = await runMigrations(pool);
    const seeds = await runSeed(pool);
    console.log(
      `dev:db ready on postgres://${USER}:${PASSWORD}@127.0.0.1:${PORT}/${DATABASE}`,
    );
    console.log(
      `dev:db migrations applied=${migration.applied} skipped=${migration.skipped} seeds=${seeds.length}`,
    );
    console.log('dev:db running; press Ctrl-C to stop');
    await new Promise<void>((resolve) => {
      const stop = () => resolve();
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
    });
  } finally {
    await pool.end();
    await embedded.stop();
    console.log('dev:db stopped');
  }
}

main().catch((error) => {
  console.error('dev:db failed', error);
  process.exitCode = 1;
});
