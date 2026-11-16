import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import type { TestDatabase } from './helpers/test-database.js';
import { startTestDatabase } from './helpers/test-database.js';
import { runMigrations } from '../src/db/migrate.js';
import { runSeed } from '../src/db/seed.js';
import { loadAppConfig } from '../src/repositories/config-repository.js';

let db: TestDatabase;

before(async () => {
  db = await startTestDatabase();
}, { timeout: 180_000 });

after(async () => {
  await db.close();
});

async function count(table: string): Promise<number> {
  const result = await db.pool.query(`SELECT count(*)::int AS count FROM ${table}`);
  return Number(result.rows[0]?.['count']);
}

describe('schema and reference data', () => {
  it('applies all migrations and is idempotent', async () => {
    const report = await runMigrations(db.pool);
    assert.deepEqual(report.applied, []);
    assert.equal(report.skipped, 9);

    const applied = await db.pool.query(
      `SELECT name FROM schema_migrations ORDER BY name`,
    );
    assert.deepEqual(
      applied.rows.map((row) => row['name']),
      [
        '0001_reference_data.sql',
        '0002_identity_access.sql',
        '0003_recipients_trading.sql',
        '0004_idempotency.sql',
        '0005_financial_operations.sql',
        '0006_ledger.sql',
        '0007_guards.sql',
        '0008_p2p_matching.sql',
        '0009_market_depth.sql',
      ],
    );
  });

  it('runs seed twice without changing row counts', async () => {
    const tables = [
      'countries',
      'currencies',
      'carriers',
      'hubs',
      'payout_rails',
      'tiers',
      'trade_status_transitions',
      'ledger_accounts',
      'config_versions',
    ];
    const before = new Map<string, number>();
    for (const table of tables) before.set(table, await count(table));

    const files = await runSeed(db.pool);
    assert.equal(files.length, 1);

    for (const table of tables) {
      assert.equal(await count(table), before.get(table), `${table} changed on reseed`);
    }
  });

  it('serves the exact five-list /config shape the Flutter parser needs', async () => {
    const config = await loadAppConfig(db.pool);

    assert.ok(config.currencies.length >= 6);
    assert.ok(config.hubs.length >= 5);
    assert.ok(config.payoutRails.length >= 18);
    assert.ok(config.countries.length >= 6);
    assert.ok(config.carriers.length >= 15);

    const tzs = config.currencies.find((currency) => currency.code === 'TZS');
    const kes = config.currencies.find((currency) => currency.code === 'KES');
    assert.equal(tzs?.decimals, 0);
    assert.equal(kes?.decimals, 2);

    assert.equal(config.countries[0]?.code, 'TZ');
    assert.equal(config.countries[0]?.dialCode, '255');
    assert.equal(config.countries[0]?.nationalNumberLength, 9);

    for (const rail of config.payoutRails) {
      assert.ok(['mobile_money', 'bank'].includes(rail.kind));
      assert.ok(config.countries.some((country) => country.code === rail.countryCode));
    }
    for (const hub of config.hubs) {
      assert.ok(config.countries.some((country) => country.code === hub.countryCode));
    }
    for (const carrier of config.carriers) {
      assert.doesNotThrow(() => new RegExp(carrier.prefixPattern));
      assert.ok(config.countries.some((country) => country.code === carrier.countryCode));
    }

    assert.equal(config.support, undefined);
  });

  it('does not invent support, limits or corridor pricing', async () => {
    assert.equal(await count('support_settings'), 0);
    assert.equal(await count('tier_limits'), 0);
    assert.equal(await count('corridor_settings'), 0);
  });

  it('seeds a provisional chart of accounts for every active currency', async () => {
    const result = await db.pool.query(
      `SELECT currency_code, count(*)::int AS accounts,
              bool_and(is_provisional) AS all_provisional
       FROM ledger_accounts
       GROUP BY currency_code
       ORDER BY currency_code`,
    );
    assert.equal(result.rows.length, 6);
    for (const row of result.rows) {
      assert.equal(Number(row['accounts']), 12);
      assert.equal(row['all_provisional'], true);
    }
  });

  it('rejects invalid reference rows at the database boundary', async () => {
    await assert.rejects(
      db.pool.query(
        `INSERT INTO payout_rails (id, name, country_code, kind)
         VALUES ('bad-rail', 'Bad Rail', 'TZ', 'card')`,
      ),
      /payout_rails_kind_check/,
    );
    await assert.rejects(
      db.pool.query(
        `INSERT INTO currencies (code, name, country_code, decimals)
         VALUES ('BAD', 'Bad Currency', 'TZ', 9)`,
      ),
      /currencies_decimals_check/,
    );
    await assert.rejects(
      db.pool.query(
        `INSERT INTO users (phone, display_name) VALUES ('0755000000', 'Bad Phone')`,
      ),
      /users_phone_check/,
    );
    await assert.rejects(
      db.pool.query(
        `INSERT INTO users (phone, display_name, account_type)
         VALUES ('+255700000001', 'No Hub', 'business')`,
      ),
      /users_business_hub/,
    );
  });
});
