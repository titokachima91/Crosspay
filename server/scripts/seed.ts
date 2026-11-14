import 'dotenv/config';
import { createPoolFromEnv } from '../src/db/pool.js';
import { runSeed } from '../src/db/seed.js';

const pool = createPoolFromEnv();
try {
  const files = await runSeed(pool);
  console.log(JSON.stringify({ ok: true, seeded: files }, null, 2));
} finally {
  await pool.end();
}
