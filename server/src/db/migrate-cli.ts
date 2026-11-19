import 'dotenv/config';
import { Pool } from 'pg';
import { runMigrations } from './migrate.js';

/**
 * Production migration entrypoint. It runs the same migration set as
 * `npm run migrate`, but from the compiled output so the runtime image does
 * not need tsx or dev dependencies.
 *
 * Exit code 0 means every migration was applied or already recorded.
 */
const connectionString = process.env['DATABASE_URL'];
if (!connectionString) {
  console.error('DATABASE_URL is required');
  process.exit(1);
}

const ssl =
  process.env['DATABASE_SSL'] === 'true'
    ? { rejectUnauthorized: false }
    : undefined;

const pool = new Pool({
  connectionString,
  ssl,
  max: 1,
  connectionTimeoutMillis: 10_000,
});

try {
  const report = await runMigrations(pool);
  console.log(
    JSON.stringify({
      ok: true,
      applied: report.applied,
      skipped: report.skipped,
    }),
  );
} catch (error) {
  console.error(
    JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }),
  );
  process.exitCode = 1;
} finally {
  await pool.end();
}
