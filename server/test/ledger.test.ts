import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { TestDatabase } from './helpers/test-database.js';
import { startTestDatabase } from './helpers/test-database.js';
import { withTransaction } from '../src/db/pool.js';
import {
  getJournalLines,
  JournalValidationError,
  postJournal,
  reverseJournal,
} from '../src/ledger.js';

let db: TestDatabase;

before(async () => {
  db = await startTestDatabase();
}, { timeout: 180_000 });

after(async () => {
  await db.close();
});

async function accounts(currency = 'TZS'): Promise<Map<string, string>> {
  const result = await db.pool.query(
    `SELECT code, id FROM ledger_accounts WHERE currency_code = $1`,
    [currency],
  );
  return new Map(result.rows.map((row) => [String(row['code']), String(row['id'])]));
}

function postingKey(label: string): string {
  return `${label}:${randomBytes(6).toString('hex')}`;
}

describe('double-entry ledger', () => {
  it('posts a balanced transaction and derives account balances', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    const revenue = map.get('3000-TZS');
    assert.ok(cash && revenue);

    const key = postingKey('test');
    const { transactionId } = await withTransaction(db.pool, (client) =>
      postJournal(client, {
        postingKey: key,
        kind: 'fee_earned',
        currencyCode: 'TZS',
        lines: [
          { accountId: cash, amountMinor: 12_000n },
          { accountId: revenue, amountMinor: -12_000n },
        ],
      }),
    );

    const totals = await db.pool.query(
      `SELECT balance_minor, line_count FROM journal_transaction_balances WHERE transaction_id = $1`,
      [transactionId],
    );
    assert.equal(String(totals.rows[0]?.['balance_minor']), '0');
    assert.equal(Number(totals.rows[0]?.['line_count']), 2);

    const balances = await db.pool.query(
      `SELECT code, balance_minor FROM ledger_account_balances
       WHERE account_id = ANY($1::uuid[])`,
      [[cash, revenue]],
    );
    const byCode = new Map(
      balances.rows.map((row) => [String(row['code']), String(row['balance_minor'])]),
    );
    assert.equal(byCode.get('1000-TZS'), '12000');
    assert.equal(byCode.get('3000-TZS'), '-12000');
  });

  it('rejects an unbalanced transaction at commit', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    assert.ok(cash);

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const tx = await client.query(
        `INSERT INTO journal_transactions (posting_key, kind, currency_code)
         VALUES ($1, 'adjustment', 'TZS') RETURNING id`,
        [postingKey('unbalanced')],
      );
      const transactionId = String(tx.rows[0]?.['id']);
      await client.query(
        `INSERT INTO journal_lines (transaction_id, account_id, amount_minor)
         VALUES ($1, $2, 500)`,
        [transactionId, cash],
      );
      await assert.rejects(client.query('COMMIT'), /not balanced/);
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });

  it('rejects mixed account currencies', async () => {
    const tzs = await accounts('TZS');
    const usd = await accounts('USD');
    const cashTzs = tzs.get('1000-TZS');
    const cashUsd = usd.get('1000-USD');
    assert.ok(cashTzs && cashUsd);

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      const tx = await client.query(
        `INSERT INTO journal_transactions (posting_key, kind, currency_code)
         VALUES ($1, 'adjustment', 'TZS') RETURNING id`,
        [postingKey('mixed')],
      );
      const transactionId = String(tx.rows[0]?.['id']);
      await client.query(
        `INSERT INTO journal_lines (transaction_id, account_id, amount_minor)
         VALUES ($1, $2, 100), ($1, $3, -100)`,
        [transactionId, cashTzs, cashUsd],
      );
      await assert.rejects(client.query('COMMIT'), /mixes account currencies/);
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });

  it('makes ledger history append-only', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    const revenue = map.get('3000-TZS');
    assert.ok(cash && revenue);

    const { transactionId } = await withTransaction(db.pool, (client) =>
      postJournal(client, {
        postingKey: postingKey('immutable'),
        kind: 'adjustment',
        currencyCode: 'TZS',
        lines: [
          { accountId: cash, amountMinor: 1_000n },
          { accountId: revenue, amountMinor: -1_000n },
        ],
      }),
    );

    await assert.rejects(
      db.pool.query(`UPDATE journal_lines SET amount_minor = 2000 WHERE transaction_id = $1`, [
        transactionId,
      ]),
      /append-only/,
    );
    await assert.rejects(
      db.pool.query(`DELETE FROM journal_lines WHERE transaction_id = $1`, [transactionId]),
      /append-only/,
    );
    await assert.rejects(
      db.pool.query(`UPDATE journal_transactions SET kind = 'adjustment' WHERE id = $1`, [
        transactionId,
      ]),
      /append-only/,
    );
    await assert.rejects(
      db.pool.query(`DELETE FROM journal_transactions WHERE id = $1`, [transactionId]),
      /append-only/,
    );
  });

  it('rejects duplicate posting keys so a retried webhook cannot post twice', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    const revenue = map.get('3000-TZS');
    assert.ok(cash && revenue);
    const key = postingKey('duplicate');

    const lines = [
      { accountId: cash, amountMinor: 700n },
      { accountId: revenue, amountMinor: -700n },
    ];

    await withTransaction(db.pool, (client) =>
      postJournal(client, {
        postingKey: key,
        kind: 'deposit_received',
        currencyCode: 'TZS',
        lines,
      }),
    );

    await assert.rejects(
      withTransaction(db.pool, (client) =>
        postJournal(client, {
          postingKey: key,
          kind: 'deposit_received',
          currencyCode: 'TZS',
          lines,
        }),
      ),
      /duplicate key value|unique constraint/,
    );
  });

  it('reverses a transaction with an exact opposite entry', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    const revenue = map.get('3000-TZS');
    assert.ok(cash && revenue);

    const original = await withTransaction(db.pool, (client) =>
      postJournal(client, {
        postingKey: postingKey('reverse-original'),
        kind: 'fee_earned',
        currencyCode: 'TZS',
        lines: [
          { accountId: cash, amountMinor: 9_000n },
          { accountId: revenue, amountMinor: -9_000n },
        ],
      }),
    );

    const originalLines = await withTransaction(db.pool, (client) =>
      getJournalLines(client, original.transactionId),
    );
    assert.equal(originalLines.length, 2);

    const reversal = await withTransaction(db.pool, (client) =>
      reverseJournal(client, {
        originalTransactionId: original.transactionId,
        postingKey: postingKey('reverse-new'),
      }),
    );

    const reversalLines = await withTransaction(db.pool, (client) =>
      getJournalLines(client, reversal.transactionId),
    );
    const originalByAccount = new Map(
      originalLines.map((line) => [line.accountId, line.amountMinor]),
    );
    for (const line of reversalLines) {
      assert.equal(line.amountMinor, -(originalByAccount.get(line.accountId) ?? 0n));
    }
  });

  it('rejects a locally unbalanced journal before it reaches the database', async () => {
    const map = await accounts();
    const cash = map.get('1000-TZS');
    const revenue = map.get('3000-TZS');
    assert.ok(cash && revenue);

    await assert.rejects(
      withTransaction(db.pool, (client) =>
        postJournal(client, {
          postingKey: postingKey('invalid'),
          kind: 'adjustment',
          currencyCode: 'TZS',
          lines: [
            { accountId: cash, amountMinor: 100n },
            { accountId: revenue, amountMinor: -99n },
          ],
        }),
      ),
      JournalValidationError,
    );
  });
});
