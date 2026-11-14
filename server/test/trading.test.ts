import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { TestDatabase } from './helpers/test-database.js';
import { createQuote, createUser, insertTrade, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox, hashRequest } from '../src/crypto.js';
import {
  beginIdempotent,
  completeIdempotent,
  IdempotencyInProgressError,
  IdempotencyKeyReusedError,
} from '../src/idempotency.js';
import {
  consumeQuote,
  markExpiredQuotes,
  QuoteExpiredError,
  QuoteNotActiveError,
  QuoteNotFoundError,
} from '../src/quotes.js';

let db: TestDatabase;

before(async () => {
  db = await startTestDatabase();
}, { timeout: 180_000 });

after(async () => {
  await db.close();
});

async function consumeAndCreateTrade(
  userId: string,
  quote: { quoteId: string; p2pRouteId: string; bankRouteId: string },
): Promise<string> {
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    await consumeQuote(client, { quoteId: quote.quoteId, userId });
    const tradeId = await insertTrade(client, { userId, quote });
    await client.query('COMMIT');
    return tradeId;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

describe('quotes, trades and timeline', () => {
  it('consumes a quote exactly once', async () => {
    const user = await createUser(db.pool);
    const quote = await createQuote(db.pool, user);
    const tradeId = await consumeAndCreateTrade(user, quote);

    const trade = await db.pool.query(
      `SELECT status, quote_id, route FROM trades WHERE id = $1`,
      [tradeId],
    );
    assert.equal(trade.rows[0]?.['status'], 'pending_deposit');
    assert.equal(trade.rows[0]?.['quote_id'], quote.quoteId);

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      await assert.rejects(
        consumeQuote(client, { quoteId: quote.quoteId, userId: user }),
        QuoteNotActiveError,
      );
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });

  it('rejects an expired quote and an unowned quote', async () => {
    const user = await createUser(db.pool);
    const other = await createUser(db.pool);
    const now = Date.now();
    const expired = await createQuote(db.pool, user, {
      quotedAt: new Date(now - 60 * 60 * 1000),
      expiresAt: new Date(now - 60 * 1000),
    });

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      await assert.rejects(
        consumeQuote(client, { quoteId: expired.quoteId, userId: user }),
        QuoteExpiredError,
      );
      await assert.rejects(
        consumeQuote(client, { quoteId: expired.quoteId, userId: other }),
        QuoteNotFoundError,
      );
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });

  it('marks an expired active quote without touching consumed history', async () => {
    const user = await createUser(db.pool);
    const now = Date.now();
    const quote = await createQuote(db.pool, user, {
      quotedAt: new Date(now - 60 * 60 * 1000),
      expiresAt: new Date(now - 60 * 1000),
    });

    const client = await db.pool.connect();
    try {
      const count = await markExpiredQuotes(client);
      assert.ok(count >= 1);
      const status = await client.query(`SELECT status FROM quotes WHERE id = $1`, [
        quote.quoteId,
      ]);
      assert.equal(status.rows[0]?.['status'], 'expired');
    } finally {
      client.release();
    }
  });

  it('writes an append-only timeline and rejects illegal transitions', async () => {
    const user = await createUser(db.pool);
    const quote = await createQuote(db.pool, user);
    const tradeId = await consumeAndCreateTrade(user, quote);

    const initial = await db.pool.query(
      `SELECT status, actor FROM trade_events WHERE trade_id = $1 ORDER BY id`,
      [tradeId],
    );
    assert.deepEqual(initial.rows.map((row) => row['status']), ['pending_deposit']);
    assert.equal(initial.rows[0]?.['actor'], 'system');

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('crosspay.actor', 'provider', true)`);
      await client.query(`UPDATE trades SET status = 'escrowed' WHERE id = $1`, [tradeId]);
      await client.query('COMMIT');
    } finally {
      client.release();
    }

    const afterEscrow = await db.pool.query(
      `SELECT status, actor FROM trade_events WHERE trade_id = $1 ORDER BY id`,
      [tradeId],
    );
    assert.deepEqual(
      afterEscrow.rows.map((row) => row['status']),
      ['pending_deposit', 'escrowed'],
    );
    assert.equal(afterEscrow.rows[1]?.['actor'], 'provider');

    await assert.rejects(
      db.pool.query(`UPDATE trades SET status = 'completed' WHERE id = $1`, [tradeId]),
      /illegal trade transition escrowed -> completed/,
    );

    await assert.rejects(
      db.pool.query(`UPDATE trade_events SET status = 'failed' WHERE trade_id = $1`, [
        tradeId,
      ]),
      /append-only/,
    );
    await assert.rejects(
      db.pool.query(`DELETE FROM trade_events WHERE trade_id = $1`, [tradeId]),
      /append-only/,
    );
  });
});

describe('idempotency', () => {
  it('allows only one concurrent request per key and replays the original result', async () => {
    const user = await createUser(db.pool);
    const crypto = new CryptoBox(randomBytes(32));
    const key = `test-${randomBytes(8).toString('hex')}`;
    const requestHash = hashRequest({ quoteId: 'quote-1', route: 'p2p' });

    const first = await db.pool.connect();
    const second = await db.pool.connect();
    try {
      await first.query('BEGIN');
      const acquired = await beginIdempotent(
        first,
        { userId: user, scope: 'trade.initiate', key, requestHash },
        crypto,
      );
      assert.equal(acquired.state, 'acquired');
      if (acquired.state !== 'acquired') throw new Error('unreachable');

      await second.query('BEGIN');
      let secondResolved = false;
      const replayPromise = beginIdempotent(
        second,
        { userId: user, scope: 'trade.initiate', key, requestHash },
        crypto,
      ).then((result) => {
        secondResolved = true;
        return result;
      });

      await new Promise((resolve) => setTimeout(resolve, 150));
      assert.equal(secondResolved, false, 'the duplicate must wait for the first transaction');

      await completeIdempotent(
        first,
        {
          id: acquired.id,
          status: 'succeeded',
          responseStatus: 201,
          responseBody: { tradeId: 'trade-1', status: 'pending_deposit' },
          resourceType: 'trade',
          resourceId: 'trade-1',
        },
        crypto,
      );
      await first.query('COMMIT');

      const replay = await replayPromise;
      assert.equal(replay.state, 'replay');
      if (replay.state !== 'replay') throw new Error('unreachable');
      assert.equal(replay.responseStatus, 201);
      assert.deepEqual(replay.responseBody, {
        tradeId: 'trade-1',
        status: 'pending_deposit',
      });
      assert.equal(replay.resourceId, 'trade-1');
      await second.query('COMMIT');
    } finally {
      first.release();
      second.release();
    }
  });

  it('rejects a different body with the same key and reports committed in-progress work', async () => {
    const user = await createUser(db.pool);
    const crypto = new CryptoBox(randomBytes(32));
    const key = `test-${randomBytes(8).toString('hex')}`;
    const requestHash = hashRequest({ quoteId: 'quote-2' });
    const expiresAt = new Date(Date.now() + 60_000);

    await db.pool.query(
      `INSERT INTO idempotency_keys
         (user_id, scope, key, request_hash, status, created_at, expires_at)
       VALUES ($1, 'trade.initiate', $2, $3, 'in_progress', now(), $4)`,
      [user, key, requestHash, expiresAt],
    );

    const client = await db.pool.connect();
    try {
      await client.query('BEGIN');
      await assert.rejects(
        beginIdempotent(
          client,
          {
            userId: user,
            scope: 'trade.initiate',
            key,
            requestHash: hashRequest({ quoteId: 'different' }),
          },
          crypto,
        ),
        IdempotencyKeyReusedError,
      );
      await client.query('ROLLBACK');

      await client.query('BEGIN');
      await assert.rejects(
        beginIdempotent(
          client,
          { userId: user, scope: 'trade.initiate', key, requestHash },
          crypto,
        ),
        IdempotencyInProgressError,
      );
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });

  it('lets a waiting request acquire the key when the first transaction rolls back', async () => {
    const user = await createUser(db.pool);
    const crypto = new CryptoBox(randomBytes(32));
    const key = `test-${randomBytes(8).toString('hex')}`;
    const requestHash = hashRequest({ quoteId: 'quote-3' });

    const first = await db.pool.connect();
    const second = await db.pool.connect();
    try {
      await first.query('BEGIN');
      const acquired = await beginIdempotent(
        first,
        { userId: user, scope: 'beneficiary.create', key, requestHash },
        crypto,
      );
      assert.equal(acquired.state, 'acquired');
      await first.query('ROLLBACK');

      await second.query('BEGIN');
      const retry = await beginIdempotent(
        second,
        { userId: user, scope: 'beneficiary.create', key, requestHash },
        crypto,
      );
      assert.equal(retry.state, 'acquired');
      await second.query('ROLLBACK');
    } finally {
      first.release();
      second.release();
    }
  });
});
