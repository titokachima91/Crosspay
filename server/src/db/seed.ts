import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import type { Pool } from 'pg';

const DEFAULT_SEED_DIR = fileURLToPath(new URL('../../db/seed', import.meta.url));

/**
 * Runs idempotent seed files in name order. The SQL itself uses ON CONFLICT,
 * so a second run changes no rows and still succeeds.
 */
export async function runSeed(pool: Pool, seedDir = DEFAULT_SEED_DIR): Promise<string[]> {
  const client = await pool.connect();
  try {
    await client.query(`SELECT pg_advisory_lock(hashtext('crosspay:seed'))`);

    const files = (await readdir(seedDir))
      .filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name))
      .sort();
    if (files.length === 0) throw new Error(`no seed files found in ${seedDir}`);

    for (const name of files) {
      const sql = await readFile(`${seedDir}/${name}`, 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw new Error(`seed ${name} failed: ${(error as Error).message}`, {
          cause: error,
        });
      }
    }

    return files;
  } finally {
    try {
      await client.query(`SELECT pg_advisory_unlock(hashtext('crosspay:seed'))`);
    } catch {
      // Closing the session releases the lock.
    }
    client.release();
  }
}
