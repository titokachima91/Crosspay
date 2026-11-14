import { startTestDatabase } from '../test/helpers/test-database.js';
import { loadAppConfig } from '../src/repositories/config-repository.js';

// Developer convenience: verifies a fresh database without installing
// PostgreSQL or Docker. Production/staging uses `npm run verify` against the
// real DATABASE_URL instead.
const db = await startTestDatabase();
try {
  const config = await loadAppConfig(db.pool);
  const counts = await db.pool.query(`
    SELECT
      (SELECT count(*) FROM schema_migrations)::int AS migrations,
      (SELECT count(*) FROM currencies)::int AS currencies,
      (SELECT count(*) FROM payout_rails)::int AS payout_rails,
      (SELECT count(*) FROM ledger_accounts)::int AS ledger_accounts,
      (SELECT count(*) FROM tier_limits)::int AS tier_limits,
      (SELECT count(*) FROM support_settings)::int AS support_settings
  `);

  const imbalance = await db.pool.query(
    `SELECT count(*)::int AS count FROM journal_transaction_balances WHERE balance_minor <> 0`,
  );

  const failures: string[] = [];
  if (config.currencies.length === 0) failures.push('currencies empty');
  if (config.hubs.length === 0) failures.push('hubs empty');
  if (config.payoutRails.length === 0) failures.push('payoutRails empty');
  if (config.countries.length === 0) failures.push('countries empty');
  if (config.carriers.length === 0) failures.push('carriers empty');
  if (Number(imbalance.rows[0]?.['count'] ?? 0) > 0) failures.push('ledger imbalance');

  console.log(
    JSON.stringify(
      {
        ok: failures.length === 0,
        failures,
        counts: counts.rows[0],
        configLists: {
          currencies: config.currencies.length,
          hubs: config.hubs.length,
          payoutRails: config.payoutRails.length,
          countries: config.countries.length,
          carriers: config.carriers.length,
        },
        supportConfigured: config.support !== undefined,
      },
      null,
      2,
    ),
  );

  if (failures.length > 0) process.exitCode = 1;
} finally {
  await db.close();
}
