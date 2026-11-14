import 'dotenv/config';
import { createPoolFromEnv } from '../src/db/pool.js';
import { runMigrations } from '../src/db/migrate.js';

const pool = createPoolFromEnv();
try {
  const report = await runMigrations(pool);
  console.log(
    JSON.stringify(
      {
        ok: true,
        applied: report.applied,
        skipped: report.skipped,
      },
      null,
      2,
    ),
  );
} finally {
  await pool.end();
}
