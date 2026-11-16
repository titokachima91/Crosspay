import assert from 'node:assert/strict';
import { createHmac, randomBytes } from 'node:crypto';
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
  PaymentRejectedError,
  type CollectionInput,
  type PaymentCollection,
  type PaymentPayout,
  type PaymentProvider,
  type PaymentRefund,
  type PayoutInput,
  type RefundInput,
} from '../src/providers/payments.js';

/**
 * Deterministic provider that behaves like a real aggregator: collection and
 * payout references are idempotency keys, and every state change is explicit.
 */
class FakePaymentProvider implements PaymentProvider {
  readonly name = 'fake';
  payoutMode: 'pending' | 'failed' | 'reject' = 'pending';
  private readonly collections = new Map<string, PaymentCollection>();
  private readonly payouts = new Map<string, PaymentPayout>();
  private sequence = 0;

  createCollection(input: CollectionInput): Promise<PaymentCollection> {
    const existing = this.collections.get(input.transactionRef);
    if (existing) return Promise.resolve(existing);
    this.sequence += 1;
    const collection: PaymentCollection = {
      checkoutRequestId: `chk_${String(this.sequence).padStart(4, '0')}`,
      transactionRef: input.transactionRef,
      provider: 'MPESA_TZ',
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
    throw new Error(`no collection ${checkoutRequestId}`);
  }

  createPayout(input: PayoutInput): Promise<PaymentPayout> {
    if (this.payoutMode === 'reject') {
      return Promise.reject(
        new PaymentRejectedError(422, 'WALLET_NOT_FOUND', 'The recipient wallet was not found'),
      );
    }
    const existing = this.payouts.get(input.transactionRef);
    if (existing) return Promise.resolve(existing);
    this.sequence += 1;
    const payout: PaymentPayout = {
      payoutId: `po_${String(this.sequence).padStart(4, '0')}`,
      transactionRef: input.transactionRef,
      provider: 'MPESA_TZ',
      phoneNumber: input.phoneNumber,
      amountMinor: input.amountMinor,
      currency: input.currency,
      feeMinor: 0,
      status: this.payoutMode === 'failed' ? 'FAILED' : 'PENDING',
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
    return Promise.reject(new PaymentRejectedError(404, 'BANK_ACCOUNT_NOT_FOUND', 'Not used'));
  }

  transfer(): Promise<never> {
    return Promise.reject(new PaymentRejectedError(404, 'BANK_TRANSFER_NOT_FOUND', 'Not used'));
  }
}

let db: TestDatabase;
let app: FastifyInstance;
let provider: FakePaymentProvider;
let context: AppContext;
let user: string;
let token: string;

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
    paymentWebhookSecret: Buffer.from('webhook-secret'),
    paymentWebhookMaxSkewSeconds: 300,
    p2pEnabled: false,
    publicApiUrl: 'https://api.crosspay.test',
  };

  user = await createUser(db.pool, {
    phone: '+255755930001',
    displayName: 'Payout Owner',
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

  app = await buildServer(context);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

function auth(): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

function write(key: string): Record<string, string> {
  return { ...auth(), 'x-idempotency-key': key };
}

function recipient() {
  return {
    railId: 'mpesa-ke',
    account: '+254712345678',
    name: 'Payout Recipient',
    reference: 'PAYOUT TEST',
  };
}

interface Initiated {
  trade: {
    id: string;
    reference: string;
    status: string;
    sendAmountMinor: number;
    feeMinor: number;
    receiveAmountMinor: number;
  };
  collection: { amountMinor: number };
}

async function initiate(key: string): Promise<Initiated> {
  const quote = await createQuote(db.pool, user);
  const response = await app.inject({
    method: 'POST',
    url: '/api/v1/trade/initiate',
    headers: write(key),
    payload: { quoteId: quote.quoteId, route: 'p2p', recipient: recipient() },
  });
  assert.equal(response.statusCode, 201, response.body);
  return response.json() as Initiated;
}

async function externalReference(tradeId: string): Promise<string> {
  const result = await db.pool.query<{ external_reference: string }>(
    `SELECT external_reference FROM payment_attempts WHERE trade_id = $1
     ORDER BY created_at DESC LIMIT 1`,
    [tradeId],
  );
  const reference = result.rows[0]?.external_reference;
  assert.ok(reference);
  return reference;
}

async function escrow(key: string): Promise<Initiated> {
  const trade = await initiate(key);
  const reference = await externalReference(trade.trade.id);
  provider.completeCollection(reference, 'SUCCESS');
  const claim = await app.inject({
    method: 'POST',
    url: `/api/v1/trades/${trade.trade.id}/payment-claim`,
    headers: write(`${key}-claim`),
  });
  assert.equal(claim.statusCode, 200, claim.body);
  assert.equal((claim.json() as { trade: { status: string } }).trade.status, 'escrowed');
  return trade;
}

async function accountBalance(code: string): Promise<bigint> {
  const result = await db.pool.query<{ balance_minor: string }>(
    `SELECT balance_minor::text FROM ledger_account_balances WHERE code = $1`,
    [code],
  );
  return BigInt(result.rows[0]?.balance_minor ?? '0');
}

async function tradeAccountBalance(tradeId: string, code: string): Promise<bigint> {
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

async function journalSummary(tradeId: string) {
  const result = await db.pool.query<{
    kind: string;
    currency_code: string;
    balance_minor: string;
    line_count: number;
  }>(
    `SELECT t.kind, t.currency_code, b.balance_minor::text, b.line_count
     FROM journal_transactions t
     JOIN journal_transaction_balances b ON b.transaction_id = t.id
     WHERE t.trade_id = $1
     ORDER BY t.id`,
    [tradeId],
  );
  return result.rows;
}

function signature(rawBody: string, timestamp: string): string {
  return createHmac('sha256', 'webhook-secret')
    .update(`${timestamp}.${rawBody}`)
    .digest('hex');
}

async function webhook(payload: unknown, key: string) {
  const raw = JSON.stringify(payload);
  const timestamp = String(Date.now());
  return app.inject({
    method: 'POST',
    url: '/api/v1/webhooks/payments/fake',
    headers: {
      'content-type': 'application/json',
      'x-kachi-timestamp': timestamp,
      'x-kachi-signature': signature(raw, timestamp),
      'x-request-id': key,
    },
    payload: raw,
  });
}

describe('B2.4 payouts, refunds and callbacks', () => {
  it('pays an escrowed trade and books linked single-currency FX journals', async () => {
    provider.payoutMode = 'pending';
    const trade = await escrow('payout-happy');
    const first = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/disburse`,
      headers: write('payout-happy-disburse-1'),
    });
    assert.equal(first.statusCode, 202, first.body);
    const pending = first.json() as { trade: { status: string }; payout: { status: string } };
    assert.equal(pending.trade.status, 'disbursing');
    assert.equal(pending.payout.status, 'submitted');

    const payout = provider.completePayout(`${trade.trade.reference}-OUT`, 'SUCCESS');
    assert.equal(payout.status, 'SUCCESS');

    const replay = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/disburse`,
      headers: write('payout-happy-disburse-2'),
    });
    assert.equal(replay.statusCode, 200, replay.body);
    const completed = replay.json() as { trade: { status: string }; payout: { status: string } };
    assert.equal(completed.trade.status, 'completed');
    assert.equal(completed.payout.status, 'paid');

    const journals = await journalSummary(trade.trade.id);
    assert.deepEqual(
      journals.map((entry) => entry.kind).sort(),
      ['deposit_received', 'fee_earned', 'fx_conversion', 'fx_conversion', 'payout_sent'].sort(),
    );
    for (const entry of journals) {
      assert.equal(BigInt(entry.balance_minor), 0n, `${entry.kind} did not balance`);
      assert.equal(entry.line_count >= 2, true);
    }

    const pspFee = BigInt(Math.floor(trade.collection.amountMinor / 200));
    const netFee = BigInt(trade.trade.feeMinor) - pspFee;
    assert.equal(await accountBalance('1000-TZS'), BigInt(trade.trade.sendAmountMinor) + netFee);
    assert.equal(await accountBalance('2000-TZS'), 0n);
    assert.equal(await accountBalance('5000-TZS'), -BigInt(trade.trade.sendAmountMinor));
    assert.equal(await accountBalance('5000-KES'), BigInt(trade.trade.receiveAmountMinor));
    assert.equal(await accountBalance('2000-KES'), 0n);
    assert.equal(await accountBalance('1000-KES'), -BigInt(trade.trade.receiveAmountMinor));
    assert.equal(await accountBalance('3000-TZS'), -netFee);
    assert.equal(await accountBalance('6000-KES'), 0n);
  });

  it('refunds the payer when the payout fails and reverses the collection journals', async () => {
    const trade = await escrow('payout-failure');
    provider.payoutMode = 'failed';
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/disburse`,
      headers: write('payout-failure-disburse'),
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as {
      trade: { status: string };
      payout: { status: string };
    };
    assert.equal(body.trade.status, 'refunded');
    assert.equal(body.payout.status, 'failed');

    const journals = await journalSummary(trade.trade.id);
    const kinds = journals.map((entry) => entry.kind).sort();
    assert.deepEqual(
      kinds,
      ['deposit_received', 'fee_earned', 'refund_paid', 'refund_paid'].sort(),
    );
    for (const entry of journals) assert.equal(BigInt(entry.balance_minor), 0n);

    assert.equal(await tradeAccountBalance(trade.trade.id, '1000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(trade.trade.id, '2000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(trade.trade.id, '3000-TZS'), 0n);

    const refund = await db.pool.query<{ status: string }>(
      `SELECT status FROM refunds WHERE trade_id = $1`,
      [trade.trade.id],
    );
    assert.equal(refund.rows[0]?.status, 'paid');
    provider.payoutMode = 'pending';
  });

  it('refunds the payer when the payout provider rejects before paying', async () => {
    const trade = await escrow('payout-reject');
    provider.payoutMode = 'reject';
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/disburse`,
      headers: write('payout-reject-disburse'),
    });
    assert.equal(response.statusCode, 422, response.body);
    assert.equal(
      (response.json() as { error: { code: string } }).error.code,
      'WALLET_NOT_FOUND',
    );

    const stored = await db.pool.query<{ status: string }>(
      `SELECT status FROM trades WHERE id = $1`,
      [trade.trade.id],
    );
    assert.equal(stored.rows[0]?.status, 'refunded');
    const refund = await db.pool.query<{ status: string }>(
      `SELECT status FROM refunds WHERE trade_id = $1`,
      [trade.trade.id],
    );
    assert.equal(refund.rows[0]?.status, 'paid');
    for (const entry of await journalSummary(trade.trade.id)) {
      assert.equal(BigInt(entry.balance_minor), 0n);
    }
    provider.payoutMode = 'pending';
  });

  it('refunds an escrowed collection and refuses after a payout', async () => {
    provider.payoutMode = 'pending';
    const refundable = await escrow('refund-happy');
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${refundable.trade.id}/refund`,
      headers: write('refund-happy-action'),
      payload: { reason: 'customer_request' },
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as { trade: { status: string }; refund: { status: string } };
    assert.equal(body.trade.status, 'refunded');
    assert.equal(body.refund.status, 'paid');
    for (const entry of await journalSummary(refundable.trade.id)) {
      assert.equal(BigInt(entry.balance_minor), 0n);
    }
    assert.equal(await tradeAccountBalance(refundable.trade.id, '1000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(refundable.trade.id, '2000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(refundable.trade.id, '3000-TZS'), 0n);

    const paid = await escrow('refund-after-payout');
    await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${paid.trade.id}/disburse`,
      headers: write('refund-after-payout-disburse'),
    });
    provider.completePayout(`${paid.trade.reference}-OUT`, 'SUCCESS');
    await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${paid.trade.id}/disburse`,
      headers: write('refund-after-payout-resume'),
    });
    const refused = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${paid.trade.id}/refund`,
      headers: write('refund-after-payout-action'),
    });
    assert.equal(refused.statusCode, 409, refused.body);
    assert.equal(
      (refused.json() as { error: { code: string } }).error.code,
      'PAYOUT_ALREADY_SENT',
    );
  });

  it('refunds a collection that arrives after the sender cancelled', async () => {
    const trade = await initiate('late-collection');
    const cancel = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/cancel`,
      headers: write('late-collection-cancel'),
    });
    assert.equal(cancel.statusCode, 200, cancel.body);
    assert.equal((cancel.json() as { trade: { status: string } }).trade.status, 'cancelled');

    const reference = await externalReference(trade.trade.id);
    provider.completeCollection(reference, 'SUCCESS');
    const claim = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/payment-claim`,
      headers: write('late-collection-claim'),
    });
    assert.equal(claim.statusCode, 200, claim.body);
    const body = claim.json() as {
      trade: { status: string };
      paymentStatus: string;
      refundStatus?: string;
    };
    assert.equal(body.trade.status, 'cancelled');
    assert.equal(body.paymentStatus, 'SUCCESS');
    assert.equal(body.refundStatus, 'paid');

    for (const entry of await journalSummary(trade.trade.id)) {
      assert.equal(BigInt(entry.balance_minor), 0n);
    }
    assert.equal(await tradeAccountBalance(trade.trade.id, '1000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(trade.trade.id, '2000-TZS'), 0n);
    assert.equal(await tradeAccountBalance(trade.trade.id, '3000-TZS'), 0n);
  });

  it('confirms a collection once from a signed callback and rejects replays and forgeries', async () => {
    const trade = await initiate('webhook-collection');
    const reference = await externalReference(trade.trade.id);
    provider.completeCollection(reference, 'SUCCESS');

    const payload = {
      checkoutRequestId: reference,
      transactionRef: undefined,
      amountMinor: trade.collection.amountMinor,
      currency: 'TZS',
      status: 'SUCCESS',
    };
    const first = await webhook(payload, 'wh-1');
    assert.equal(first.statusCode, 200, first.body);
    assert.equal((first.json() as { received: boolean }).received, true);

    const stored = await db.pool.query<{ status: string }>(
      `SELECT status FROM trades WHERE id = $1`,
      [trade.trade.id],
    );
    assert.equal(stored.rows[0]?.status, 'escrowed');
    const event = await db.pool.query<{ status: string; signature_verified: boolean }>(
      `SELECT status, signature_verified FROM payment_events WHERE trade_id = $1`,
      [trade.trade.id],
    );
    assert.equal(event.rows[0]?.status, 'processed');
    assert.equal(event.rows[0]?.signature_verified, true);

    const replay = await webhook(payload, 'wh-2');
    assert.equal(replay.statusCode, 200);
    assert.equal((replay.json() as { replay?: boolean }).replay, true);
    const journalCount = await db.pool.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM journal_transactions WHERE trade_id = $1`,
      [trade.trade.id],
    );
    assert.equal(journalCount.rows[0]?.count, '2');

    const raw = JSON.stringify(payload);
    const timestamp = String(Date.now());
    const forged = await app.inject({
      method: 'POST',
      url: '/api/v1/webhooks/payments/fake',
      headers: {
        'content-type': 'application/json',
        'x-kachi-timestamp': timestamp,
        'x-kachi-signature': '00'.repeat(32),
      },
      payload: raw,
    });
    assert.equal(forged.statusCode, 401);
    assert.equal(
      (forged.json() as { error: { code: string } }).error.code,
      'WEBHOOK_SIGNATURE_INVALID',
    );

    const stale = await app.inject({
      method: 'POST',
      url: '/api/v1/webhooks/payments/fake',
      headers: {
        'content-type': 'application/json',
        'x-kachi-timestamp': String(Date.now() - 3_600_000),
        'x-kachi-signature': signature(raw, String(Date.now() - 3_600_000)),
      },
      payload: raw,
    });
    assert.equal(stale.statusCode, 401);
    assert.equal(
      (stale.json() as { error: { code: string } }).error.code,
      'WEBHOOK_TIMESTAMP_INVALID',
    );
  });

  it('completes a trade from a signed payout callback', async () => {
    provider.payoutMode = 'pending';
    const trade = await escrow('webhook-payout');
    const reference = `${trade.trade.reference}-OUT`;
    const disburse = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${trade.trade.id}/disburse`,
      headers: write('webhook-payout-disburse'),
    });
    assert.equal(disburse.statusCode, 202, disburse.body);
    const payout = provider.completePayout(reference, 'SUCCESS');

    const response = await webhook(
      { payoutId: payout.payoutId, status: 'SUCCESS', currency: 'KES', amountMinor: payout.amountMinor },
      'wh-payout',
    );
    assert.equal(response.statusCode, 200, response.body);
    assert.equal(
      (response.json() as { tradeStatus?: string }).tradeStatus,
      'completed',
    );
    const stored = await db.pool.query<{ status: string }>(
      `SELECT status FROM trades WHERE id = $1`,
      [trade.trade.id],
    );
    assert.equal(stored.rows[0]?.status, 'completed');
    const replay = await webhook(
      { payoutId: payout.payoutId, status: 'SUCCESS', currency: 'KES', amountMinor: payout.amountMinor },
      'wh-payout-2',
    );
    assert.equal((replay.json() as { replay?: boolean }).replay, true);
  });
});
