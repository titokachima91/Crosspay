import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { createQuote, createUser, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { signAccessToken } from '../src/http/auth.js';
import { buildServer } from '../src/http/server.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { DisabledPricingProvider } from '../src/providers/pricing.js';
import type {
  CollectionInput,
  PaymentCollection,
  PaymentPayout,
  PaymentProvider,
  PaymentRefund,
  PayoutInput,
  RefundInput,
} from '../src/providers/payments.js';

class FakePaymentProvider implements PaymentProvider {
  readonly name = 'fake';
  private readonly collections = new Map<string, PaymentCollection>();
  private readonly payouts = new Map<string, PaymentPayout>();
  readonly failPayoutRefs = new Set<string>();
  private sequence = 0;

  createCollection(input: CollectionInput): Promise<PaymentCollection> {
    const existing = this.collections.get(input.transactionRef);
    if (existing) return Promise.resolve(existing);
    this.sequence += 1;
    const collection: PaymentCollection = {
      checkoutRequestId: `chk_${String(this.sequence).padStart(4, '0')}`,
      transactionRef: input.transactionRef,
      provider: 'FAKE',
      phoneNumber: input.phoneNumber,
      amountMinor: input.amountMinor,
      currency: input.currency,
      feeMinor: Math.floor(input.amountMinor / 200),
      status: 'PENDING',
    };
    this.collections.set(input.transactionRef, collection);
    return Promise.resolve(collection);
  }

  getCollection(checkoutRequestId: string): Promise<PaymentCollection | null> {
    for (const collection of this.collections.values()) {
      if (collection.checkoutRequestId === checkoutRequestId) return Promise.resolve(collection);
    }
    return Promise.resolve(null);
  }

  completeCollection(checkoutRequestId: string, status = 'SUCCESS'): void {
    for (const [reference, collection] of this.collections) {
      if (collection.checkoutRequestId === checkoutRequestId) {
        this.collections.set(reference, { ...collection, status });
        return;
      }
    }
  }

  createPayout(input: PayoutInput): Promise<PaymentPayout> {
    const existing = this.payouts.get(input.transactionRef);
    if (existing) return Promise.resolve(existing);
    this.sequence += 1;
    const payout: PaymentPayout = {
      payoutId: `po_${String(this.sequence).padStart(4, '0')}`,
      transactionRef: input.transactionRef,
      provider: 'FAKE',
      phoneNumber: input.phoneNumber,
      amountMinor: input.amountMinor,
      currency: input.currency,
      feeMinor: 0,
      status: this.failPayoutRefs.has(input.transactionRef) ? 'FAILED' : 'PENDING',
    };
    this.payouts.set(input.transactionRef, payout);
    return Promise.resolve(payout);
  }

  getPayout(payoutId: string): Promise<PaymentPayout | null> {
    for (const payout of this.payouts.values()) {
      if (payout.payoutId === payoutId) return Promise.resolve(payout);
    }
    return Promise.resolve(null);
  }

  completePayout(reference: string, status = 'SUCCESS'): PaymentPayout {
    const payout = this.payouts.get(reference);
    if (!payout) throw new Error(`no payout ${reference}`);
    const next = { ...payout, status };
    this.payouts.set(reference, next);
    return next;
  }

  refund(input: RefundInput): Promise<PaymentRefund> {
    let currency = 'TZS';
    for (const collection of this.collections.values()) {
      if (collection.checkoutRequestId === input.requestId) currency = collection.currency;
    }
    this.sequence += 1;
    return Promise.resolve({
      refundId: `rf_${String(this.sequence).padStart(4, '0')}`,
      requestId: input.requestId,
      amountMinor: input.amountMinor,
      currency,
      status: 'REFUNDED',
      feeRefundMinor: 0,
    });
  }

  getBankAccount(): Promise<never> {
    return Promise.reject(new Error('not used'));
  }

  transfer(): Promise<never> {
    return Promise.reject(new Error('not used'));
  }
}

let db: TestDatabase;
let app: FastifyInstance;
let provider: FakePaymentProvider;
let context: AppContext;
let tokenA: string;
let tokenB: string;
let userA: string;
let userB: string;

before(async () => {
  db = await startTestDatabase();
  provider = new FakePaymentProvider();
  context = {
    pool: db.pool,
    crypto: new CryptoBox(randomBytes(32)),
    smsSender: new DisabledSmsSender(),
    pricingProvider: new DisabledPricingProvider(),
    paymentProvider: provider,
    jwtSecret: randomBytes(32),
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 3600,
    idempotencyTtlSeconds: 86_400,
    limitTimezone: 'UTC',
    collectionPushTimeoutSeconds: 90,
    collectionPollIntervalSeconds: 4,
    paymentWebhookSecret: null,
    paymentWebhookMaxSkewSeconds: 300,
    p2pEnabled: true,
  };

  userA = await createUser(db.pool, {
    phone: '+255755940001',
    displayName: 'TZS Sender',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  userB = await createUser(db.pool, {
    phone: '+254712940002',
    displayName: 'KES Sender',
    kycStatus: 'verified',
    limitCurrency: 'KES',
  });
  tokenA = await signAccessToken({ userId: userA, secret: context.jwtSecret });
  tokenB = await signAccessToken({ userId: userB, secret: context.jwtSecret });
  await db.pool.query(
    `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
     VALUES ('starter', 'TZS', 100000000), ('starter', 'KES', 100000000)
     ON CONFLICT (tier_code, currency_code)
     DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
  );
  await db.pool.query(
    `INSERT INTO p2p_corridors
       (send_currency, receive_currency, enabled, exposure_cap_minor,
        match_deadline_seconds, spread_bps)
     VALUES ('TZS', 'KES', true, 100000000, 600, 50),
            ('KES', 'TZS', true, 100000000, 600, 50)`,
  );

  app = await buildServer(context);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

function write(token: string, key: string): Record<string, string> {
  return { authorization: `Bearer ${token}`, 'x-idempotency-key': key };
}

async function quote(
  userId: string,
  input: {
    sendCurrency: string;
    receiveCurrency: string;
    sendAmountMinor: bigint;
    payoutMinor: bigint;
    feeMinor: bigint;
  },
): Promise<string> {
  const created = await createQuote(db.pool, userId, {
    sendCurrency: input.sendCurrency,
    receiveCurrency: input.receiveCurrency,
    sendAmountMinor: input.sendAmountMinor,
  });
  await db.pool.query(
    `UPDATE quote_routes
     SET payout_minor = $2, fee_minor = $3, total_debit_minor = $4
     WHERE quote_id = $1`,
    [
      created.quoteId,
      input.payoutMinor.toString(),
      input.feeMinor.toString(),
      (input.sendAmountMinor + input.feeMinor).toString(),
    ],
  );
  return created.quoteId;
}

async function escrow(
  token: string,
  userId: string,
  input: {
    key: string;
    railId: string;
    account: string;
    sendCurrency: string;
    receiveCurrency: string;
    sendAmountMinor: bigint;
    payoutMinor: bigint;
    feeMinor: bigint;
  },
): Promise<{ id: string; reference: string }> {
  const quoteId = await quote(userId, input);
  const initiated = await app.inject({
    method: 'POST',
    url: '/api/v1/trade/initiate',
    headers: write(token, `${input.key}-initiate`),
    payload: {
      quoteId,
      route: 'p2p',
      recipient: {
        railId: input.railId,
        account: input.account,
        name: 'Match Recipient',
        reference: 'MATCH',
      },
    },
  });
  assert.equal(initiated.statusCode, 201, initiated.body);
  const body = initiated.json() as { trade: { id: string; reference: string } };
  const attempt = await db.pool.query<{ external_reference: string }>(
    `SELECT external_reference FROM payment_attempts WHERE trade_id = $1
     ORDER BY created_at DESC LIMIT 1`,
    [body.trade.id],
  );
  const reference = attempt.rows[0]?.external_reference;
  assert.ok(reference);
  provider.completeCollection(reference, 'SUCCESS');
  const claim = await app.inject({
    method: 'POST',
    url: `/api/v1/trades/${body.trade.id}/payment-claim`,
    headers: write(token, `${input.key}-claim`),
  });
  assert.equal(claim.statusCode, 200, claim.body);
  const claimed = claim.json() as { trade: { status: string } };
  return { id: body.trade.id, reference: body.trade.reference };
}

async function tradeStatus(id: string, token: string): Promise<string> {
  const response = await app.inject({
    method: 'GET',
    url: `/api/v1/trades/${id}`,
    headers: { authorization: `Bearer ${token}` },
  });
  return (response.json() as { status: string }).status;
}

async function matchRows(): Promise<Array<{ id: string; status: string }>> {
  const result = await db.pool.query<{ id: string; status: string }>(
    `SELECT id, status FROM p2p_matches ORDER BY created_at DESC`,
  );
  return result.rows;
}

async function journalsFor(tradeId: string) {
  const result = await db.pool.query<{ kind: string; currency_code: string; balance_minor: string }>(
    `SELECT t.kind, t.currency_code, b.balance_minor::text
     FROM journal_transactions t
     JOIN journal_transaction_balances b ON b.transaction_id = t.id
     WHERE t.trade_id = $1
     ORDER BY t.created_at, t.id`,
    [tradeId],
  );
  return result.rows;
}

async function tradeBalance(tradeId: string, code: string): Promise<bigint> {
  const result = await db.pool.query<{ balance_minor: string }>(
    `SELECT COALESCE(sum(l.amount_minor), 0)::text AS balance_minor
     FROM journal_lines l
     JOIN journal_transactions t ON t.id = l.transaction_id
     JOIN ledger_accounts a ON a.id = l.account_id
     WHERE t.trade_id = $1 AND a.code = $2`,
    [tradeId, code],
  );
  return BigInt(result.rows[0]?.balance_minor ?? '0');
}

async function matchPair(key: string) {
  const a = await escrow(tokenA, userA, {
    key: `${key}-a`,
    railId: 'mpesa-ke',
    account: '+254712345678',
    sendCurrency: 'TZS',
    receiveCurrency: 'KES',
    sendAmountMinor: 1_000_000n,
    payoutMinor: 54_054n,
    feeMinor: 10_000n,
  });
  const b = await escrow(tokenB, userB, {
    key: `${key}-b`,
    railId: 'mpesa-tz',
    account: '+255712345678',
    sendCurrency: 'KES',
    receiveCurrency: 'TZS',
    sendAmountMinor: 55_000n,
    payoutMinor: 1_000_000n,
    feeMinor: 550n,
  });
  const matches = await matchRows();
  return { a, b, match: matches[0] };
}

describe('B4 P2P matching', () => {
  it('matches two funded opposite trades FIFO and releases both payouts', async () => {
    const { a, b, match } = await matchPair('match-happy');
    assert.ok(match, 'expected a match row');
    assert.equal(match.status, 'locked');
    assert.equal(await tradeStatus(a.id, tokenA), 'matched');
    assert.equal(await tradeStatus(b.id, tokenB), 'matched');

    const first = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-happy-disburse-1'),
    });
    assert.equal(first.statusCode, 200, first.body);
    const firstBody = first.json() as {
      match: { status: string };
      legs: Array<{ trade: { status: string }; payout: { status: string } }>;
    };
    assert.equal(firstBody.match.status, 'locked');
    assert.equal(firstBody.legs[0]?.payout.status, 'submitted');

    provider.completePayout(`${a.reference}-OUT`, 'SUCCESS');
    const second = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-happy-disburse-2'),
    });
    assert.equal(second.statusCode, 200, second.body);
    const secondBody = second.json() as {
      match: { status: string };
      legs: Array<{ trade: { status: string }; payout: { status: string } }>;
    };
    assert.equal(secondBody.legs[0]?.trade.status, 'completed');
    assert.equal(secondBody.legs[1]?.payout.status, 'submitted');

    provider.completePayout(`${b.reference}-OUT`, 'SUCCESS');
    const third = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-happy-disburse-3'),
    });
    assert.equal(third.statusCode, 200, third.body);
    const thirdBody = third.json() as {
      match: { status: string };
      legs: Array<{ trade: { status: string }; payout: { status: string } }>;
    };
    assert.equal(thirdBody.match.status, 'released');
    assert.deepEqual(
      thirdBody.legs.map((leg) => leg.trade.status),
      ['completed', 'completed'],
    );

    const refreshed = await matchRows();
    assert.equal(refreshed[0]?.status, 'released');

    for (const trade of [a, b]) {
      for (const journal of await journalsFor(trade.id)) {
        assert.equal(BigInt(journal.balance_minor), 0n, `${trade.reference} ${journal.kind}`);
      }
    }
    const pairBalance = async (code: string): Promise<bigint> => {
      const result = await db.pool.query<{ balance_minor: string }>(
        `SELECT COALESCE(sum(l.amount_minor), 0)::text AS balance_minor
         FROM journal_lines l
         JOIN journal_transactions t ON t.id = l.transaction_id
         JOIN ledger_accounts a ON a.id = l.account_id
         WHERE t.trade_id IN ($1, $2) AND a.code = $3`,
        [a.id, b.id, code],
      );
      return BigInt(result.rows[0]?.balance_minor ?? '0');
    };
    assert.equal(await pairBalance('2000-KES'), 0n);
    assert.equal(await pairBalance('2000-TZS'), 0n);
    assert.equal(await pairBalance('3100-KES'), -946n);
    assert.equal(await pairBalance('3100-TZS'), 0n);
  });

  it('leaves a funded trade in matching when no opposite trade exists', async () => {
    const a = await escrow(tokenA, userA, {
      key: 'match-queue-a',
      railId: 'mpesa-ke',
      account: '+254712345679',
      sendCurrency: 'TZS',
      receiveCurrency: 'KES',
      sendAmountMinor: 500_000n,
      payoutMinor: 27_027n,
      feeMinor: 5_000n,
    });
    assert.equal(await tradeStatus(a.id, tokenA), 'matching');
    const deadline = await db.pool.query<{ match_deadline_at: Date | null }>(
      `SELECT match_deadline_at FROM trades WHERE id = $1`,
      [a.id],
    );
    assert.ok(deadline.rows[0]?.match_deadline_at);
  });

  it('expires and refunds a trade that passes the match deadline', async () => {
    const a = await escrow(tokenA, userA, {
      key: 'match-timeout-a',
      railId: 'mpesa-ke',
      account: '+254712345680',
      sendCurrency: 'TZS',
      receiveCurrency: 'KES',
      sendAmountMinor: 400_000n,
      payoutMinor: 21_621n,
      feeMinor: 4_000n,
    });
    await db.pool.query(
      `UPDATE trades SET match_deadline_at = now() - interval '1 second' WHERE id = $1`,
      [a.id],
    );
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${a.id}/match`,
      headers: write(tokenA, 'match-timeout-run'),
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as { matched: boolean; expired?: boolean; trade: { status: string } };
    assert.equal(body.matched, false);
    assert.equal(body.expired, true);
    assert.equal(body.trade.status, 'refunded');
  });

  it('refunds both legs when the first payout fails before any settlement', async () => {
    const { a, b, match } = await matchPair('match-first-fail');
    assert.ok(match);
    provider.failPayoutRefs.add(`${a.reference}-OUT`);
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-first-fail-disburse'),
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as {
      match: { status: string };
      legs: Array<{ payout: { status: string } }>;
    };
    assert.equal(body.match.status, 'failed');
    assert.equal(body.legs[0]?.payout.status, 'failed');
    assert.equal(await tradeStatus(a.id, tokenA), 'refunded');
    assert.equal(await tradeStatus(b.id, tokenB), 'refunded');
    for (const trade of [a, b]) {
      for (const journal of await journalsFor(trade.id)) {
        assert.equal(BigInt(journal.balance_minor), 0n);
      }
    }
    provider.failPayoutRefs.clear();
  });

  it('completes the first leg and compensates the second when it fails', async () => {
    const { a, b, match } = await matchPair('match-second-fail');
    assert.ok(match);

    const first = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-second-fail-disburse-1'),
    });
    assert.equal(first.statusCode, 200, first.body);
    provider.completePayout(`${a.reference}-OUT`, 'SUCCESS');
    provider.failPayoutRefs.add(`${b.reference}-OUT`);

    const second = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${match.id}/disburse`,
      headers: write(tokenA, 'match-second-fail-disburse-2'),
    });
    assert.equal(second.statusCode, 200, second.body);
    const body = second.json() as { match: { status: string } };
    assert.equal(body.match.status, 'failed');
    assert.equal(await tradeStatus(a.id, tokenA), 'completed');
    assert.equal(await tradeStatus(b.id, tokenB), 'refunded');

    const compensation = await journalsFor(b.id);
    assert.ok(compensation.some((journal) => journal.kind === 'p2p_compensation'));
    const compensationBalance = await db.pool.query<{ balance_minor: string }>(
      `SELECT b.balance_minor::text
       FROM journal_transactions t
       JOIN journal_transaction_balances b ON b.transaction_id = t.id
       WHERE t.trade_id = $1 AND t.kind = 'p2p_compensation'`,
      [b.id],
    );
    assert.equal(BigInt(compensationBalance.rows[0]?.balance_minor ?? '1'), 0n);
    assert.equal(
      (await tradeBalance(a.id, '1000-KES')) + (await tradeBalance(b.id, '1000-KES')),
      0n,
    );
    assert.equal(await tradeBalance(b.id, '7000-KES'), -54_054n);
    provider.failPayoutRefs.clear();
  });
});
