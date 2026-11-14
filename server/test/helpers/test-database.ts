import { randomInt } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import EmbeddedPostgres from 'embedded-postgres';
import { Pool } from 'pg';
import type { PoolClient } from 'pg';
import { runMigrations } from '../../src/db/migrate.js';
import { runSeed } from '../../src/db/seed.js';

export interface TestDatabase {
  pool: Pool;
  close: () => Promise<void>;
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address === 'string') {
        server.close();
        reject(new Error('could not allocate a test port'));
        return;
      }
      const port = address.port;
      server.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

/**
 * Starts an ephemeral PostgreSQL 17 cluster, applies every migration and seed,
 * and returns a pool. No local Postgres or Docker installation is required.
 */
export async function startTestDatabase(): Promise<TestDatabase> {
  const databaseDir = await mkdtemp(path.join(tmpdir(), 'crosspay-pg-'));
  const port = await freePort();
  const user = 'postgres';
  const password = 'postgres';
  const database = 'crosspay_test';
  const embedded = new EmbeddedPostgres({
    databaseDir,
    port,
    user,
    password,
    persistent: false,
    autoRehydrateSymlinks: true,
    onLog: () => undefined,
    onError: () => undefined,
  });

  let pool: Pool | undefined;
  try {
    await embedded.initialise();
    await embedded.start();
    await embedded.createDatabase(database);

    pool = new Pool({
      host: '127.0.0.1',
      port,
      user,
      password,
      database,
      max: 8,
      connectionTimeoutMillis: 10_000,
    });

    await runMigrations(pool);
    await runSeed(pool);

    return {
      pool,
      close: async () => {
        try {
          await pool?.end();
          // pg may emit the server's shutdown notice on a socket that is still
          // closing; let the event loop finish the FIN before stopping Postgres.
          await new Promise((resolve) => setTimeout(resolve, 250));
        } catch (error) {
          console.error('test database pool close failed', error);
        }
        try {
          await embedded.stop();
        } catch (error) {
          console.error('test database stop failed', error);
        }
        try {
          await rm(databaseDir, { recursive: true, force: true });
        } catch (error) {
          console.error('test database directory cleanup failed', error);
        }
      },
    };
  } catch (error) {
    await pool?.end().catch(() => undefined);
    await embedded.stop().catch(() => undefined);
    await rm(databaseDir, { recursive: true, force: true });
    throw error;
  }
}

export async function createUser(
  pool: Pool,
  overrides: {
    phone?: string;
    displayName?: string;
    accountType?: 'personal' | 'business';
    hubId?: string;
    kycStatus?: 'not_started' | 'pending' | 'verified' | 'rejected';
    limitCurrency?: string;
  } = {},
): Promise<string> {
  const accountType = overrides.accountType ?? 'personal';
  const kycStatus = overrides.kycStatus ?? 'verified';
  const phone =
    overrides.phone ?? `+2557${String(randomInt(0, 100_000_000)).padStart(8, '0')}`;
  const hubId =
    overrides.hubId ?? (accountType === 'business' ? 'dar-es-salaam' : null);
  const limitCurrency =
    overrides.limitCurrency ?? (kycStatus === 'verified' ? 'TZS' : null);

  const result = await pool.query(
    `INSERT INTO users
       (phone, phone_verified_at, display_name, account_type, hub_id,
        kyc_status, tier_code, limit_currency_code)
     VALUES ($1, now(), $2, $3, $4, $5, 'starter', $6)
     RETURNING id`,
    [
      phone,
      overrides.displayName ?? 'Test User',
      accountType,
      hubId,
      kycStatus,
      limitCurrency,
    ],
  );
  return String(result.rows[0]?.['id']);
}

export interface TestQuote {
  quoteId: string;
  p2pRouteId: string;
  bankRouteId: string;
}

export async function createQuote(
  pool: Pool,
  userId: string,
  options: {
    expiresAt?: Date;
    quotedAt?: Date;
    sendAmountMinor?: bigint;
    sendCurrency?: string;
    receiveCurrency?: string;
  } = {},
): Promise<TestQuote> {
  const sendCurrency = options.sendCurrency ?? 'TZS';
  const receiveCurrency = options.receiveCurrency ?? 'KES';
  const sendAmount = options.sendAmountMinor ?? 1_000_000n;
  const quotedAt = options.quotedAt ?? new Date();
  const expiresAt = options.expiresAt ?? new Date(Date.now() + 5 * 60 * 1000);

  const quote = await pool.query(
    `INSERT INTO quotes
       (user_id, send_currency, receive_currency, send_amount_minor, rate,
        quoted_at, expires_at)
     VALUES ($1, $2, $3, $4, 18.5, $5, $6)
     RETURNING id`,
    [userId, sendCurrency, receiveCurrency, sendAmount.toString(), quotedAt, expiresAt],
  );
  const quoteId = String(quote.rows[0]?.['id']);

  const route = await pool.query(
    `INSERT INTO quote_routes
       (quote_id, route, fee_bps, fee_minor, payout_minor, total_debit_minor,
        estimated_min_seconds, estimated_max_seconds, is_recommended, is_available,
        matching_density_percent, status_code, status_level, fee_breakdown)
     VALUES
       ($1, 'p2p', 100, 10000, 54054, 1010000, 30, 120, true, true, 78,
        'high_matching_density', 'healthy', '[{"code":"platform_fee","amountMinor":10000}]'),
       ($1, 'bank', 150, 15000, 54054, 1015000, 60, 300, false, true, NULL,
        NULL, 'healthy', '[{"code":"platform_fee","amountMinor":15000}]')
     RETURNING id, route`,
    [quoteId],
  );
  const p2pRouteId = String(route.rows.find((row) => row['route'] === 'p2p')?.['id']);
  const bankRouteId = String(route.rows.find((row) => row['route'] === 'bank')?.['id']);

  return { quoteId, p2pRouteId, bankRouteId };
}

export async function insertTrade(
  db: Pool | PoolClient,
  input: {
    userId: string;
    quote: TestQuote;
    status?: string;
    reference?: string;
  },
): Promise<string> {
  const result = await db.query(
    `INSERT INTO trades
       (reference, user_id, quote_id, quote_route_id, route, status,
        send_currency, receive_currency, send_amount_minor, fee_minor, fee_bps,
        receive_amount_minor, rate, beneficiary_name, beneficiary_rail_id,
        beneficiary_account_encrypted, beneficiary_account_last4)
     VALUES ($1, $2, $3, $4, 'p2p', $5, 'TZS', 'KES', 1000000, 10000, 100,
             54054, 18.5, 'Amina Hassan', 'mpesa-ke', $6, '4567')
     RETURNING id`,
    [
      input.reference ?? `CP-${randomInt(100_000, 999_999)}`,
      input.userId,
      input.quote.quoteId,
      input.quote.p2pRouteId,
      input.status ?? 'pending_deposit',
      Buffer.from([1, 2, 3, 4]),
    ],
  );
  return String(result.rows[0]?.['id']);
}
