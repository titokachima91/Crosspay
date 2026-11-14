import 'dotenv/config';
import { createPoolFromEnv } from '../src/db/pool.js';
import { migrationStatus } from '../src/db/migrate.js';
import { loadAppConfig } from '../src/repositories/config-repository.js';

const pool = createPoolFromEnv();
try {
  const config = await loadAppConfig(pool);
  const migrations = await migrationStatus(pool);

  const countsResult = await pool.query(`
    SELECT
      (SELECT count(*) FROM currencies)::int AS currencies,
      (SELECT count(*) FROM countries)::int AS countries,
      (SELECT count(*) FROM carriers)::int AS carriers,
      (SELECT count(*) FROM hubs)::int AS hubs,
      (SELECT count(*) FROM payout_rails)::int AS payout_rails,
      (SELECT count(*) FROM tiers)::int AS tiers,
      (SELECT count(*) FROM ledger_accounts)::int AS ledger_accounts
  `);
  const counts = countsResult.rows[0] as Record<string, number>;

  const imbalance = await pool.query(
    `SELECT count(*)::int AS count
     FROM journal_transaction_balances
     WHERE balance_minor <> 0`,
  );
  const imbalancedTransactions = Number(imbalance.rows[0]?.['count'] ?? 0);

  const missingKind = await pool.query(
    `SELECT count(*)::int AS count
     FROM payout_rails
     WHERE kind IS NULL OR kind NOT IN ('mobile_money', 'bank')`,
  );

  const failures: string[] = [];
  if (config.currencies.length === 0) failures.push('currencies list is empty');
  if (config.hubs.length === 0) failures.push('hubs list is empty');
  if (config.payoutRails.length === 0) failures.push('payoutRails list is empty');
  if (config.countries.length === 0) failures.push('countries list is empty');
  if (config.carriers.length === 0) failures.push('carriers list is empty');
  if (imbalancedTransactions > 0) {
    failures.push(`${imbalancedTransactions} journal transaction(s) are imbalanced`);
  }
  if (Number(missingKind.rows[0]?.['count'] ?? 0) > 0) {
    failures.push('one or more payout rails has no valid kind');
  }

  console.log(
    JSON.stringify(
      {
        ok: failures.length === 0,
        failures,
        migrations: migrations.map((migration) => migration.name),
        counts,
        configLists: {
          currencies: config.currencies.length,
          hubs: config.hubs.length,
          payoutRails: config.payoutRails.length,
          countries: config.countries.length,
          carriers: config.carriers.length,
        },
        supportConfigured: config.support !== undefined,
        imbalancedTransactions,
      },
      null,
      2,
    ),
  );

  if (failures.length > 0) process.exitCode = 1;
} finally {
  await pool.end();
}
