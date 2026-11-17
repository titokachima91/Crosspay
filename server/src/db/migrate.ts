import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import type { Pool } from 'pg';

const DEFAULT_MIGRATIONS_DIR = fileURLToPath(
  new URL('../../db/migrations', import.meta.url),
);

export interface MigrationReport {
  applied: string[];
  skipped: number;
}

interface AppliedMigration {
  name: string;
  checksum: string;
}

function checksum(sql: string): string {
  return createHash('sha256').update(sql, 'utf8').digest('hex');
}

/**
 * Forward-only migration runner. Each migration runs in its own transaction
 * and is checksum-locked: an edited file that was already applied is drift and
 * stops the run instead of silently changing production.
 */
export async function runMigrations(
  pool: Pool,
  migrationsDir = DEFAULT_MIGRATIONS_DIR,
): Promise<MigrationReport> {
  const client = await pool.connect();
  const report: MigrationReport = { applied: [], skipped: 0 };

  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name          text PRIMARY KEY,
        checksum      text NOT NULL,
        applied_at    timestamptz NOT NULL DEFAULT now(),
        execution_ms  integer NOT NULL CHECK (execution_ms >= 0)
      )
    `);

    await client.query(`SELECT pg_advisory_lock(hashtext('crosspay:migrations'))`);

    const files = (await readdir(migrationsDir))
      .filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name))
      .sort();

    if (files.length === 0) {
      throw new Error(`no migration files found in ${migrationsDir}`);
    }

    const appliedResult = await client.query<AppliedMigration>(
      `SELECT name, checksum FROM schema_migrations ORDER BY name`,
    );
    const applied = new Map(appliedResult.rows.map((row) => [row.name, row.checksum]));

    for (const name of applied.keys()) {
      if (!files.includes(name)) {
        throw new Error(`applied migration ${name} is missing from ${migrationsDir}`);
      }
    }

    for (const name of files) {
      const sql = await readFile(`${migrationsDir}/${name}`, 'utf8');
      const digest = checksum(sql);
      const knownChecksum = applied.get(name);

      if (knownChecksum !== undefined) {
        if (knownChecksum !== digest) {
          throw new Error(
            `migration ${name} changed after it was applied (checksum drift)`,
          );
        }
        report.skipped += 1;
        continue;
      }

      const startedAt = Date.now();
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query(
          `INSERT INTO schema_migrations (name, checksum, execution_ms)
           VALUES ($1, $2, $3)`,
          // A clock step during a long migration must not fail the deploy.
          [name, digest, Math.max(0, Date.now() - startedAt)],
        );
        await client.query('COMMIT');
        report.applied.push(name);
      } catch (error) {
        await client.query('ROLLBACK');
        throw new Error(`migration ${name} failed: ${(error as Error).message}`, {
          cause: error,
        });
      }
    }

    return report;
  } finally {
    try {
      await client.query(`SELECT pg_advisory_unlock(hashtext('crosspay:migrations'))`);
    } catch {
      // The connection may already be broken; releasing it closes the session.
    }
    client.release();
  }
}

export async function migrationStatus(pool: Pool): Promise<AppliedMigration[]> {
  const result = await pool.query<AppliedMigration>(
    `SELECT name, checksum FROM schema_migrations ORDER BY name`,
  );
  return result.rows;
}
