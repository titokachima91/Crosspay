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

class FakeProvider implements PaymentProvider {
  readonly name = 'fake';
  readonly failPayoutRefs = new Set<string>();
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
let noAdminApp: FastifyInstance;
let provider: FakeProvider;
let context: AppContext;
let user: string;
let token: string;
const ADMIN_KEY = 'test-admin-key';
let providerId = '';
let orderId = '';

before(async () => {
  db = await startTestDatabase();
  provider = new FakeProvider();
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
    publicApiUrl: 'https://api.crosspay.test',
    adminApiKey: ADMIN_KEY,
  };
  user = await createUser(db.pool, {
    phone: '+255755970001',
    displayName: 'Liquidity User',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  token = await signAccessToken({ userId: user, secret: context.jwtSecret });
  await db.pool.query(
    `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
     VALUES ('starter', 'TZS', 100000000)
     ON CONFLICT (tier_code, currency_code)
     DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
  );
  await db.pool.query(
    `INSERT INTO p2p_corridors
       (send_currency, receive_currency, enabled, exposure_cap_minor,
        match_deadline_seconds, spread_bps, estimated_settle_seconds,
        min_amount_minor, max_amount_minor)
     VALUES ('TZS', 'KES', true, 1000000000, 600, 50, 120, 1000, 100000000)`,
  );

  app = await buildServer(context);
  await app.ready();
  noAdminApp = await buildServer({ ...context, adminApiKey: null });
  await noAdminApp.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await noAdminApp.close();
  await db.close();
});

function write(key: string): Record<string, string> {
  return { authorization: `Bearer ${token}`, 'x-idempotency-key': key };
}

function admin(key = ADMIN_KEY): Record<string, string> {
  return { 'x-admin-key': key };
}

async function createProvider(name: string): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/api/v1/admin/liquidity/providers',
    headers: admin(),
    payload: { name },
  });
  assert.equal(response.statusCode, 201, response.body);
  return (response.json() as { provider: { id: string } }).provider.id;
}

async function createOrder(input: {
  providerId: string;
  capacityMinor: number;
  rate: number;
  maxAmountMinor?: number;
}): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/api/v1/admin/liquidity/orders',
    headers: admin(),
    payload: {
      providerId: input.providerId,
      provideCurrency: 'KES',
      receiveCurrency: 'TZS',
      capacityMinor: input.capacityMinor,
      maxAmountMinor: input.maxAmountMinor ?? input.capacityMinor,
      rate: input.rate,
      expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
      prefundReference: `LP-TEST-${randomBytes(4).toString('hex')}`,
    },
  });
  assert.equal(response.statusCode, 201, response.body);
  return (response.json() as { order: { id: string } }).order.id;
}

async function escrow(key: string): Promise<{ id: string; reference: string }> {
  const quote = await createQuote(db.pool, user);
  await db.pool.query(
    `UPDATE quote_routes
     SET payout_minor = 54054, fee_minor = 10000, total_debit_minor = 1010000
     WHERE quote_id = $1 AND route = 'p2p'`,
    [quote.quoteId],
  );
  const initiated = await app.inject({
    method: 'POST',
    url: '/api/v1/trade/initiate',
    headers: write(`${key}-initiate`),
    payload: {
      quoteId: quote.quoteId,
      route: 'p2p',
      recipient: {
        railId: 'mpesa-ke',
        account: '+254712345678',
        name: 'LP Recipient',
        reference: 'LP',
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
    headers: write(`${key}-claim`),
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

async function balance(code: string): Promise<bigint> {
  const result = await db.pool.query<{ balance_minor: string }>(
    `SELECT balance_minor::text FROM ledger_account_balances WHERE code = $1`,
    [code],
  );
  return BigInt(result.rows[0]?.balance_minor ?? '0');
}

describe('B4.4 liquidity providers and B4.5 admin', () => {
  it('matches a funded trade against an LP standing order and pays out', async () => {
    providerId = await createProvider('Desk One');
    orderId = await createOrder({ providerId, capacityMinor: 100_000, rate: 18.5 });
    assert.equal(await balance('1000-KES'), 100_000n);
    assert.equal(await balance('2050-KES'), -100_000n);

    const trade = await escrow('lp-happy');
    assert.equal(await tradeStatus(trade.id), 'matched');
    const match = await db.pool.query<{
      id: string;
      status: string;
      liquidity_order_id: string;
      sell_trade_id: string | null;
    }>(
      `SELECT id, status, liquidity_order_id, sell_trade_id
       FROM p2p_matches ORDER BY created_at DESC LIMIT 1`,
    );
    const row = match.rows[0];
    assert.ok(row);
    assert.equal(row.status, 'locked');
    assert.equal(row.liquidity_order_id, orderId);
    assert.equal(row.sell_trade_id, null);

    const remaining = await db.pool.query<{ remaining_minor: string; status: string }>(
      `SELECT remaining_minor, status FROM liquidity_orders WHERE id = $1`,
      [orderId],
    );
    assert.equal(BigInt(remaining.rows[0]?.remaining_minor ?? '0'), 45_946n);
    assert.equal(remaining.rows[0]?.status, 'active');

    const first = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${row.id}/disburse`,
      headers: write('lp-happy-disburse-1'),
    });
    assert.equal(first.statusCode, 200, first.body);
    assert.equal(
      (first.json() as { legs: Array<{ payout: { status: string } }> }).legs[0]?.payout.status,
      'submitted',
    );
    provider.completePayout(`${trade.reference}-OUT`, 'SUCCESS');
    const second = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${row.id}/disburse`,
      headers: write('lp-happy-disburse-2'),
    });
    assert.equal(second.statusCode, 200, second.body);
    const body = second.json() as { match: { status: string } };
    assert.equal(body.match.status, 'released');
    assert.equal(await tradeStatus(trade.id), 'completed');

    assert.equal(await balance('2050-KES'), -45_946n);
    assert.equal(await balance('2050-TZS'), -999_999n);
    assert.equal(await balance('3100-TZS'), -1n);
    assert.equal(await balance('1000-KES'), 45_946n);
    const imbalance = await db.pool.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM journal_transaction_balances WHERE balance_minor <> 0`,
    );
    assert.equal(imbalance.rows[0]?.count, '0');
  });

  it('releases LP capacity and refunds the customer when the payout fails', async () => {
    const failingProvider = await createProvider('Desk Two');
    const failingOrder = await createOrder({
      providerId: failingProvider,
      capacityMinor: 100_000,
      rate: 17.5,
    });
    const trade = await escrow('lp-failure');
    provider.failPayoutRefs.add(`${trade.reference}-OUT`);
    const match = await db.pool.query<{ id: string }>(
      `SELECT id FROM p2p_matches WHERE buy_trade_id = $1 ORDER BY created_at DESC LIMIT 1`,
      [trade.id],
    );
    const matchId = match.rows[0]?.id;
    assert.ok(matchId);

    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/matches/${matchId}/disburse`,
      headers: write('lp-failure-disburse'),
    });
    assert.equal(response.statusCode, 200, response.body);
    assert.equal((response.json() as { match: { status: string } }).match.status, 'failed');
    assert.equal(await tradeStatus(trade.id), 'refunded');

    const order = await db.pool.query<{ remaining_minor: string; status: string }>(
      `SELECT remaining_minor, status FROM liquidity_orders WHERE id = $1`,
      [failingOrder],
    );
    assert.equal(BigInt(order.rows[0]?.remaining_minor ?? '0'), 100_000n);
    assert.equal(order.rows[0]?.status, 'active');
    const settlement = await db.pool.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM journal_transactions
       WHERE trade_id = $1 AND kind = 'p2p_settlement'`,
      [trade.id],
    );
    assert.equal(settlement.rows[0]?.count, '0');
    provider.failPayoutRefs.clear();
  });

  it('serves the ops dashboard, requires the admin key and updates corridor policy', async () => {
    const html = await app.inject({ method: 'GET', url: '/admin' });
    assert.equal(html.statusCode, 200);
    assert.match(html.headers['content-type'] as string, /text\/html/);
    assert.match(html.body, /CrossPay Ops/);

    const anonymous = await app.inject({ method: 'GET', url: '/api/v1/admin/overview' });
    assert.equal(anonymous.statusCode, 401);
    assert.equal(
      (anonymous.json() as { error: { code: string } }).error.code,
      'ADMIN_UNAUTHORIZED',
    );

    const wrong = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/overview',
      headers: admin('wrong'),
    });
    assert.equal(wrong.statusCode, 401);

    const overview = await app.inject({
      method: 'GET',
      url: '/api/v1/admin/overview',
      headers: admin(),
    });
    assert.equal(overview.statusCode, 200, overview.body);
    const body = overview.json() as {
      corridors: Array<{ from: string; to: string; enabled: boolean; utilizationPercent: number | null }>;
      liquidityOrders: Array<{ id: string; providerName: string }>;
      alerts: unknown[];
    };
    assert.equal(body.corridors[0]?.from, 'TZS');
    assert.equal(body.corridors[0]?.enabled, true);
    assert.ok(body.liquidityOrders.some((order) => order.providerName === 'Desk One'));
    assert.ok(Array.isArray(body.alerts));

    const disabled = await app.inject({
      method: 'PATCH',
      url: '/api/v1/admin/corridors/TZS/KES',
      headers: admin(),
      payload: { enabled: false },
    });
    assert.equal(disabled.statusCode, 200, disabled.body);
    assert.equal((disabled.json() as { corridor: { enabled: boolean } }).corridor.enabled, false);
    const enabled = await app.inject({
      method: 'PATCH',
      url: '/api/v1/admin/corridors/TZS/KES',
      headers: admin(),
      payload: { enabled: true },
    });
    assert.equal(enabled.statusCode, 200, enabled.body);
    assert.equal((enabled.json() as { corridor: { enabled: boolean } }).corridor.enabled, true);

    const noAdmin = await noAdminApp.inject({
      method: 'GET',
      url: '/api/v1/admin/overview',
      headers: admin(),
    });
    assert.equal(noAdmin.statusCode, 503);
    assert.equal(
      (noAdmin.json() as { error: { code: string } }).error.code,
      'ADMIN_NOT_CONFIGURED',
    );

    const audit = await db.pool.query<{ action: string; actor_label: string }>(
      `SELECT action, actor_label FROM admin_audit_log ORDER BY created_at`,
    );
    assert.ok(audit.rows.some((row) => row.action === 'corridor.update'));
    assert.ok(audit.rows.some((row) => row.action === 'liquidity_provider.create'));
    assert.ok(audit.rows.some((row) => row.action === 'liquidity_order.create'));
    assert.ok(audit.rows.every((row) => row.actor_label === 'env-admin'));
  });

  it('returns remaining prefund when an unused LP order is cancelled', async () => {
    const cancelProvider = await createProvider('Desk Three');
    const cancelOrder = await createOrder({
      providerId: cancelProvider,
      capacityMinor: 10_000,
      rate: 18,
    });
    const before = await balance('1000-KES');
    const response = await app.inject({
      method: 'PATCH',
      url: `/api/v1/admin/liquidity/orders/${cancelOrder}`,
      headers: admin(),
      payload: { status: 'cancelled' },
    });
    assert.equal(response.statusCode, 200, response.body);
    assert.equal(await balance('1000-KES'), before - 10_000n);
    const order = await db.pool.query<{ status: string; remaining_minor: string }>(
      `SELECT status, remaining_minor FROM liquidity_orders WHERE id = $1`,
      [cancelOrder],
    );
    assert.equal(order.rows[0]?.status, 'cancelled');
    assert.equal(order.rows[0]?.remaining_minor, '10000');
  });
});
