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
import {
  PaymentUnavailableError,
  type CollectionInput,
  type PaymentCollection,
  type PaymentPayout,
  type PaymentProvider,
  type PaymentRefund,
  type PayoutInput,
  type RefundInput,
} from '../src/providers/payments.js';
import { AppError } from '../src/http/errors.js';
import { refundTrade, startDisbursement } from '../src/payments.js';
import { runWorkerPass } from '../src/worker.js';

class WorkerFakeProvider implements PaymentProvider {
  readonly name = 'fake';
  refundMode: 'ok' | 'down' = 'ok';
  private readonly collections = new Map<string, PaymentCollection>();
  private readonly payouts = new Map<string, PaymentPayout>();
  private sequence = 0;

  createCollection(input: CollectionInput): Promise<PaymentCollection> {
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
      status: 'PENDING',
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
    if (this.refundMode === 'down') {
      return Promise.reject(
        new PaymentUnavailableError('PAYMENT_PROVIDER_UNAVAILABLE', 'refund provider down'),
      );
    }
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
let provider: WorkerFakeProvider;
let context: AppContext;
let userA: string;
let userB: string;
let tokenA: string;
let tokenB: string;

before(async () => {
  db = await startTestDatabase();
  provider = new WorkerFakeProvider();
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
    phone: '+255755950001',
    displayName: 'Worker TZS',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  userB = await createUser(db.pool, {
    phone: '+254712950002',
    displayName: 'Worker KES',
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

  app = await buildServer(context);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

async function setCorridors(enabled: boolean): Promise<void> {
  await db.pool.query(
    `INSERT INTO p2p_corridors
       (send_currency, receive_currency, enabled, exposure_cap_minor,
        match_deadline_seconds, spread_bps)
     VALUES ('TZS', 'KES', $1, 100000000, 600, 50),
            ('KES', 'TZS', $1, 100000000, 600, 50)
     ON CONFLICT (send_currency, receive_currency)
     DO UPDATE SET enabled = EXCLUDED.enabled`,
    [enabled],
  );
}

function write(token: string, key: string): Record<string, string> {
  return { authorization: `Bearer ${token}`, 'x-idempotency-key': key };
}

async function quote(
  userId: string,
  sendCurrency: string,
  receiveCurrency: string,
  sendAmountMinor: bigint,
  payoutMinor: bigint,
  feeMinor: bigint,
): Promise<string> {
  const created = await createQuote(db.pool, userId, {
    sendCurrency,
    receiveCurrency,
    sendAmountMinor,
  });
  await db.pool.query(
    `UPDATE quote_routes
     SET payout_minor = $2, fee_minor = $3, total_debit_minor = $4
     WHERE quote_id = $1`,
    [
      created.quoteId,
      payoutMinor.toString(),
      feeMinor.toString(),
      (sendAmountMinor + feeMinor).toString(),
    ],
  );
  return created.quoteId;
}

async function escrow(
  token: string,
  userId: string,
  key: string,
  input: { send: string; receive: string; amount: bigint; payout: bigint; fee: bigint; rail: string; account: string },
): Promise<{ id: string; reference: string }> {
  const quoteId = await quote(userId, input.send, input.receive, input.amount, input.payout, input.fee);
  const initiated = await app.inject({
    method: 'POST',
    url: '/api/v1/trade/initiate',
    headers: write(token, `${key}-initiate`),
    payload: {
      quoteId,
      route: 'p2p',
      recipient: {
        railId: input.rail,
        account: input.account,
        name: 'Worker Recipient',
        reference: 'WORKER',
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
    headers: write(token, `${key}-claim`),
  });
  assert.equal(claim.statusCode, 200, claim.body);
  return { id: body.trade.id, reference: body.trade.reference };
}

async function tradeStatus(id: string): Promise<string> {
  const result = await db.pool.query<{ status: string }>(
    `SELECT status FROM trades WHERE id = $1`,
    [id],
  );
  return result.rows[0]?.status ?? '';
}

describe('reconciliation worker', () => {
  it('expires stale quotes', async () => {
    const created = await createQuote(db.pool, userA, {
      quotedAt: new Date(Date.now() - 3_600_000),
      expiresAt: new Date(Date.now() - 60_000),
    });
    const report = await runWorkerPass(context);
    assert.equal(report.expiredQuotes >= 1, true);
    const stored = await db.pool.query<{ status: string }>(
      `SELECT status FROM quotes WHERE id = $1`,
      [created.quoteId],
    );
    assert.equal(stored.rows[0]?.status, 'expired');
  });

  it('resumes a direct payout from the provider status', async () => {
    await setCorridors(false);
    const trade = await escrow(tokenA, userA, 'worker-direct', {
      send: 'TZS',
      receive: 'KES',
      amount: 600_000n,
      payout: 32_432n,
      fee: 6_000n,
      rail: 'mpesa-ke',
      account: '+254712345681',
    });
    const disbursed = await startDisbursement(context, { tradeId: trade.id });
    assert.equal(disbursed.payout.status, 'submitted');
    provider.completePayout(`${trade.reference}-OUT`, 'SUCCESS');

    const report = await runWorkerPass(context);
    assert.equal(report.resumedPayouts >= 1, true);
    assert.equal(await tradeStatus(trade.id), 'completed');
    await setCorridors(true);
  });

  it('expires and refunds a trade past its match deadline', async () => {
    await setCorridors(true);
    const trade = await escrow(tokenA, userA, 'worker-expire', {
      send: 'TZS',
      receive: 'KES',
      amount: 500_000n,
      payout: 27_027n,
      fee: 5_000n,
      rail: 'mpesa-ke',
      account: '+254712345682',
    });
    await db.pool.query(
      `UPDATE trades SET match_deadline_at = now() - interval '1 second' WHERE id = $1`,
      [trade.id],
    );
    const report = await runWorkerPass(context);
    assert.equal(report.expiredTrades >= 1, true);
    assert.equal(await tradeStatus(trade.id), 'refunded');
  });

  it('retries a refund left pending by a provider outage', async () => {
    await setCorridors(false);
    const trade = await escrow(tokenA, userA, 'worker-refund', {
      send: 'TZS',
      receive: 'KES',
      amount: 400_000n,
      payout: 21_621n,
      fee: 4_000n,
      rail: 'mpesa-ke',
      account: '+254712345683',
    });
    provider.refundMode = 'down';
    await assert.rejects(
      refundTrade(context, {
        userId: userA,
        tradeId: trade.id,
        reasonCode: 'customer_request',
        allowClosed: false,
      }),
      (error: unknown) =>
        error instanceof AppError &&
        error.statusCode === 503 &&
        error.code === 'PAYMENT_PROVIDER_UNAVAILABLE',
    );
    const pending = await db.pool.query<{ status: string }>(
      `SELECT status FROM refunds WHERE trade_id = $1`,
      [trade.id],
    );
    assert.equal(pending.rows[0]?.status, 'pending');

    provider.refundMode = 'ok';
    const report = await runWorkerPass(context);
    assert.equal(report.retriedRefunds >= 1, true);
    assert.equal(await tradeStatus(trade.id), 'refunded');
    const paid = await db.pool.query<{ status: string }>(
      `SELECT status FROM refunds WHERE trade_id = $1`,
      [trade.id],
    );
    assert.equal(paid.rows[0]?.status, 'paid');
  });

  it('resumes a locked match once both provider payouts succeed', async () => {
    await setCorridors(true);
    const a = await escrow(tokenA, userA, 'worker-match-a', {
      send: 'TZS',
      receive: 'KES',
      amount: 1_000_000n,
      payout: 54_054n,
      fee: 10_000n,
      rail: 'mpesa-ke',
      account: '+254712345684',
    });
    const b = await escrow(tokenB, userB, 'worker-match-b', {
      send: 'KES',
      receive: 'TZS',
      amount: 55_000n,
      payout: 1_000_000n,
      fee: 550n,
      rail: 'mpesa-tz',
      account: '+255712345685',
    });
    const match = await db.pool.query<{ id: string }>(
      `SELECT id FROM p2p_matches ORDER BY created_at DESC LIMIT 1`,
    );
    const matchId = match.rows[0]?.id;
    assert.ok(matchId);

    const first = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${matchId}/disburse`,
      headers: write(tokenA, 'worker-match-disburse'),
    });
    assert.equal(first.statusCode, 200, first.body);
    provider.completePayout(`${a.reference}-OUT`, 'SUCCESS');
    // The next pass completes the first leg and creates the second payout.
    await runWorkerPass(context);

    const second = await db.pool.query<{ provider_reference: string | null; status: string }>(
      `SELECT provider_reference, status FROM payouts WHERE trade_id = $1`,
      [b.id],
    );
    const providerReference = second.rows[0]?.provider_reference;
    assert.ok(providerReference, 'the second payout was not submitted');
    if (second.rows[0]?.status === 'submitted') {
      provider.completePayout(`${b.reference}-OUT`, 'SUCCESS');
      await runWorkerPass(context);
    }
    const matchState = await db.pool.query<{ status: string }>(
      `SELECT status FROM p2p_matches WHERE id = $1`,
      [matchId],
    );
    assert.equal(matchState.rows[0]?.status, 'released');
    assert.equal(await tradeStatus(a.id), 'completed');
    assert.equal(await tradeStatus(b.id), 'completed');
  });
});
