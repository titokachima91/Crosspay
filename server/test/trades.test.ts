import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { createQuote, createUser, insertTrade, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { signAccessToken } from '../src/http/auth.js';
import { buildServer } from '../src/http/server.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { DisabledPricingProvider } from '../src/providers/pricing.js';
import {
  DisabledPaymentProvider,
  PaymentRejectedError,
  PaymentUnavailableError,
  type CollectionInput,
  type PaymentCollection,
  type PaymentProvider,
} from '../src/providers/payments.js';

type FakeMode = 'ok' | 'reject' | 'down';

/**
 * A deterministic provider stand-in. transactionRef is its idempotency key:
 * repeating a reference returns the original collection instead of starting a
 * second one, exactly like a real aggregator must.
 */
class FakePaymentProvider implements PaymentProvider {
  readonly name = 'fake';
  mode: FakeMode = 'ok';
  createCalls = 0;
  readCalls = 0;
  readonly inputs: CollectionInput[] = [];
  private readonly byReference = new Map<string, PaymentCollection>();
  private sequence = 0;

  createCollection(input: CollectionInput): Promise<PaymentCollection> {
    this.createCalls += 1;
    if (this.mode === 'down') {
      return Promise.reject(
        new PaymentUnavailableError('PAYMENT_PROVIDER_UNAVAILABLE', 'fake provider down'),
      );
    }
    if (this.mode === 'reject') {
      return Promise.reject(
        new PaymentRejectedError(422, 'WALLET_NOT_FOUND', 'The payer wallet was not found'),
      );
    }
    const existing = this.byReference.get(input.transactionRef);
    if (existing) return Promise.resolve(existing);

    this.sequence += 1;
    this.inputs.push(input);
    const collection: PaymentCollection = {
      checkoutRequestId: `chk_${String(this.sequence).padStart(4, '0')}`,
      transactionRef: input.transactionRef,
      provider: 'MPESA_TZ',
      phoneNumber: input.phoneNumber,
      amountMinor: input.amountMinor,
      currency: input.currency,
      feeMinor: Math.floor(input.amountMinor / 200),
      status: 'PENDING',
      resultCode: 0,
      resultDesc: 'awaiting PIN',
    };
    this.byReference.set(input.transactionRef, collection);
    return Promise.resolve(collection);
  }

  getCollection(checkoutRequestId: string): Promise<PaymentCollection | null> {
    this.readCalls += 1;
    for (const collection of this.byReference.values()) {
      if (collection.checkoutRequestId === checkoutRequestId) return Promise.resolve(collection);
    }
    return Promise.resolve(null);
  }

  complete(checkoutRequestId: string, status = 'SUCCESS'): void {
    for (const [reference, collection] of this.byReference) {
      if (collection.checkoutRequestId === checkoutRequestId) {
        this.byReference.set(reference, { ...collection, status });
        return;
      }
    }
    throw new Error(`no fake collection ${checkoutRequestId}`);
  }

  createPayout(): Promise<never> { return Promise.reject(new Error('not used')); }
  getPayout(): Promise<never> { return Promise.reject(new Error('not used')); }
  refund(): Promise<never> { return Promise.reject(new Error('not used')); }
  getBankAccount(): Promise<never> { return Promise.reject(new Error('not used')); }
  transfer(): Promise<never> { return Promise.reject(new Error('not used')); }
}

let db: TestDatabase;
let app: FastifyInstance;
let provider: FakePaymentProvider;
let context: AppContext;
let user: string;
let otherUser: string;
let token: string;
let otherToken: string;

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
    p2pEnabled: false,
  };

  user = await createUser(db.pool, {
    phone: '+255755910001',
    displayName: 'Trade Owner',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  otherUser = await createUser(db.pool, {
    phone: '+255755910002',
    displayName: 'Other Trader',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  token = await signAccessToken({ userId: user, secret: context.jwtSecret });
  otherToken = await signAccessToken({ userId: otherUser, secret: context.jwtSecret });

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

function auth(accessToken = token): Record<string, string> {
  return { authorization: `Bearer ${accessToken}` };
}

function initiateHeaders(key: string, accessToken = token): Record<string, string> {
  return { ...auth(accessToken), 'x-idempotency-key': key };
}

interface InitiateBody {
  trade: {
    id: string;
    reference: string;
    route: string;
    status: string;
    sendCurrency: string;
    receiveCurrency: string;
    sendAmountMinor: number;
    feeMinor: number;
    feeBps: number;
    receiveAmountMinor: number;
    rate: number;
    beneficiaryName: string;
    createdAt: string;
  };
  collection: {
    pushSent: boolean;
    networkName?: string;
    amountMinor: number;
    pushTimeoutSeconds: number;
    pollIntervalSeconds: number;
  };
}

function recipient(overrides: { railId?: string; account?: string; name?: string } = {}) {
  return {
    railId: overrides.railId ?? 'mpesa-ke',
    account: overrides.account ?? '+254712345678',
    name: overrides.name ?? 'Amina Hassan',
    reference: 'SCHOOL FEES',
  };
}

async function freshQuote(): Promise<{ quoteId: string; p2pRouteId: string; bankRouteId: string }> {
  return createQuote(db.pool, user);
}

async function initiate(
  quoteId: string,
  options: { key?: string; route?: 'p2p' | 'bank'; recipient?: ReturnType<typeof recipient> } = {},
) {
  return app.inject({
    method: 'POST',
    url: '/api/v1/trade/initiate',
    headers: initiateHeaders(options.key ?? `initiate-${randomBytes(6).toString('hex')}`),
    payload: {
      quoteId,
      route: options.route ?? 'p2p',
      recipient: options.recipient ?? recipient(),
    },
  });
}

describe('B2.3 trade initiation', () => {
  it('creates a pending trade, snapshots the recipient and starts one collection', async () => {
    const quote = await freshQuote();
    const response = await initiate(quote.quoteId, { key: 'initiate-happy' });
    assert.equal(response.statusCode, 201, response.body);
    const body = response.json() as InitiateBody;

    assert.match(body.trade.id, /^[0-9a-f-]{36}$/);
    assert.match(body.trade.reference, /^CP-[0-9A-F]{20}$/);
    assert.equal(body.trade.route, 'p2p');
    assert.equal(body.trade.status, 'pending_deposit');
    assert.equal(body.trade.sendCurrency, 'TZS');
    assert.equal(body.trade.receiveCurrency, 'KES');
    assert.equal(body.trade.sendAmountMinor, 1_000_000);
    assert.equal(body.trade.feeMinor, 10_000);
    assert.equal(body.trade.feeBps, 100);
    assert.equal(body.trade.receiveAmountMinor, 54_054);
    assert.equal(body.trade.rate, 18.5);
    assert.equal(body.trade.beneficiaryName, 'Amina Hassan');

    assert.equal(body.collection.pushSent, true);
    assert.equal(body.collection.networkName, 'MPESA_TZ');
    assert.equal(body.collection.amountMinor, 1_010_000);
    assert.equal(body.collection.pushTimeoutSeconds, 90);
    assert.equal(body.collection.pollIntervalSeconds, 4);

    const stored = await db.pool.query(
      `SELECT status, consumed_at FROM quotes WHERE id = $1`,
      [quote.quoteId],
    );
    assert.equal(stored.rows[0]?.['status'], 'consumed');
    assert.ok(stored.rows[0]?.['consumed_at']);

    const trade = await db.pool.query(
      `SELECT route, send_amount_minor, fee_minor, receive_amount_minor,
              beneficiary_name, beneficiary_account_last4,
              beneficiary_account_encrypted, current_payment_attempt_id
       FROM trades WHERE id = $1`,
      [body.trade.id],
    );
    assert.equal(trade.rows[0]?.['route'], 'p2p');
    assert.equal(trade.rows[0]?.['beneficiary_account_last4'], '5678');
    assert.notEqual(
      Buffer.from(trade.rows[0]?.['beneficiary_account_encrypted'] as Buffer).toString('utf8'),
      '+254712345678',
    );
    assert.ok(trade.rows[0]?.['current_payment_attempt_id']);

    const attempt = await db.pool.query(
      `SELECT provider, external_reference, status, amount_minor, currency_code, push_sent
       FROM payment_attempts WHERE trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(attempt.rowCount, 1);
    assert.equal(attempt.rows[0]?.['provider'], 'fake');
    assert.match(String(attempt.rows[0]?.['external_reference']), /^chk_\d{4}$/);
    assert.equal(attempt.rows[0]?.['status'], 'sent');
    assert.equal(attempt.rows[0]?.['amount_minor'], '1010000');
    assert.equal(attempt.rows[0]?.['currency_code'], 'TZS');

    // The provider saw the trade reference as its idempotency key.
    assert.equal(provider.inputs.at(-1)?.transactionRef, body.trade.reference);
    assert.equal(provider.inputs.at(-1)?.amountMinor, 1_010_000);

    const events = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${body.trade.id}/history`,
      headers: auth(),
    });
    assert.equal(events.statusCode, 200);
    assert.deepEqual(
      (events.json() as { events: Array<{ status: string }> }).events.map((event) => event.status),
      ['pending_deposit'],
    );

    const list = await app.inject({
      method: 'GET',
      url: '/api/v1/trades',
      headers: auth(),
    });
    assert.equal(list.statusCode, 200);
    const listed = list.json() as { trades: Array<{ id: string; reference: string }> };
    assert.ok(listed.trades.some((trade) => trade.id === body.trade.id));

    const detail = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${body.trade.id}`,
      headers: auth(),
    });
    assert.equal(detail.statusCode, 200);
    assert.equal((detail.json() as { reference: string }).reference, body.trade.reference);
  });

  it('replays the original result for the same key without a second collection', async () => {
    const quote = await freshQuote();
    const created = await initiate(quote.quoteId, { key: 'initiate-replay' });
    assert.equal(created.statusCode, 201, created.body);
    const firstBody = created.json() as InitiateBody;
    const calls = provider.createCalls;

    const replay = await initiate(quote.quoteId, { key: 'initiate-replay' });
    assert.equal(replay.statusCode, 201);
    assert.equal(replay.headers['idempotency-replay'], 'true');
    assert.equal((replay.json() as InitiateBody).trade.id, firstBody.trade.id);
    assert.equal(provider.createCalls, calls);
  });

  it('refuses to spend a consumed quote with a new key', async () => {
    const quote = await freshQuote();
    const created = await initiate(quote.quoteId, { key: 'initiate-consume-1' });
    assert.equal(created.statusCode, 201);
    const calls = provider.createCalls;

    const second = await initiate(quote.quoteId, { key: 'initiate-consume-2' });
    assert.equal(second.statusCode, 409);
    assert.equal(
      (second.json() as { error: { code: string } }).error.code,
      'QUOTE_NOT_ACTIVE',
    );
    assert.equal(provider.createCalls, calls);
  });

  it('rejects an expired quote and leaves no trade behind', async () => {
    const now = Date.now();
    const quote = await createQuote(db.pool, user, {
      quotedAt: new Date(now - 3_600_000),
      expiresAt: new Date(now - 60_000),
    });
    const before = await db.pool.query(`SELECT count(*)::int AS count FROM trades`);
    const response = await initiate(quote.quoteId, { key: 'initiate-expired' });
    assert.equal(response.statusCode, 409);
    assert.equal((response.json() as { error: { code: string } }).error.code, 'QUOTE_EXPIRED');
    const afterCount = await db.pool.query(`SELECT count(*)::int AS count FROM trades`);
    assert.equal(afterCount.rows[0]?.['count'], before.rows[0]?.['count']);
  });

  it('rejects a rail that does not match the route or the receive currency', async () => {
    const quote = await freshQuote();

    const bankWithMobileRail = await initiate(quote.quoteId, {
      key: 'initiate-rail-1',
      route: 'bank',
      recipient: recipient({ railId: 'mpesa-ke' }),
    });
    assert.equal(bankWithMobileRail.statusCode, 422);
    assert.equal(
      (bankWithMobileRail.json() as { error: { code: string } }).error.code,
      'RECIPIENT_REJECTED',
    );

    const p2pWithBankRail = await initiate(quote.quoteId, {
      key: 'initiate-rail-2',
      route: 'p2p',
      recipient: recipient({ railId: 'equity-bank-ke', name: 'Bank Recipient' }),
    });
    assert.equal(p2pWithBankRail.statusCode, 422);

    const wrongCountry = await initiate(quote.quoteId, {
      key: 'initiate-rail-3',
      recipient: recipient({ railId: 'mpesa-tz' }),
    });
    assert.equal(wrongCountry.statusCode, 422);

    // A failed validation rolls back, so the same quote is still usable.
    const valid = await initiate(quote.quoteId, { key: 'initiate-rail-4' });
    assert.equal(valid.statusCode, 201, valid.body);
  });

  it('re-checks the daily limit at initiation', async () => {
    const quote = await freshQuote();
    const used = await db.pool.query(`SELECT COALESCE(sum(send_amount_minor), 0)::text AS used
                                       FROM trades WHERE user_id = $1`, [user]);
    await db.pool.query(
      `UPDATE tier_limits SET daily_limit_minor = $1
       WHERE tier_code = 'starter' AND currency_code = 'TZS'`,
      [(BigInt(String(used.rows[0]?.['used'] ?? '0')) + 999_999n).toString()],
    );
    const response = await initiate(quote.quoteId, { key: 'initiate-limit' });
    assert.equal(response.statusCode, 422);
    assert.equal((response.json() as { error: { code: string } }).error.code, 'LIMIT_EXCEEDED');
    assert.equal(
      (await db.pool.query(`SELECT status FROM quotes WHERE id = $1`, [quote.quoteId])).rows[0]?.[
        'status'
      ],
      'active',
    );

    // A trade in another currency must never be compared with a TZS limit.
    const kesQuote = await createQuote(db.pool, user, {
      sendCurrency: 'KES',
      receiveCurrency: 'TZS',
    });
    await insertTrade(db.pool, {
      userId: user,
      quote: kesQuote,
      sendCurrency: 'KES',
      receiveCurrency: 'TZS',
      sendAmountMinor: 50_000_000n,
      feeMinor: 500_000n,
      feeBps: 100,
      receiveAmountMinor: 2_702_702n,
    });
    await db.pool.query(
      `UPDATE tier_limits SET daily_limit_minor = 10000000
       WHERE tier_code = 'starter' AND currency_code = 'TZS'`,
    );
    const allowedQuote = await freshQuote();
    const allowed = await initiate(allowedQuote.quoteId, { key: 'initiate-limit-currency' });
    assert.equal(allowed.statusCode, 201, allowed.body);

    await db.pool.query(
      `UPDATE tier_limits SET daily_limit_minor = 100000000
       WHERE tier_code = 'starter' AND currency_code = 'TZS'`,
    );
  });

  it('maps provider rejection and outage to honest 4xx/503 without burning the quote', async () => {
    const quote = await freshQuote();

    provider.mode = 'reject';
    const rejected = await initiate(quote.quoteId, { key: 'initiate-provider-reject' });
    assert.equal(rejected.statusCode, 422);
    assert.equal(
      (rejected.json() as { error: { code: string } }).error.code,
      'WALLET_NOT_FOUND',
    );

    provider.mode = 'down';
    const down = await initiate(quote.quoteId, { key: 'initiate-provider-down' });
    assert.equal(down.statusCode, 503);
    assert.equal(
      (down.json() as { error: { code: string } }).error.code,
      'PAYMENT_PROVIDER_UNAVAILABLE',
    );

    provider.mode = 'ok';
    const recovered = await initiate(quote.quoteId, { key: 'initiate-provider-ok' });
    assert.equal(recovered.statusCode, 201, recovered.body);
  });

  it('returns the contract code when the payment provider is disabled', async () => {
    const disabled = await buildServer({
      ...context,
      paymentProvider: new DisabledPaymentProvider(),
    });
    const quote = await freshQuote();
    const response = await disabled.inject({
      method: 'POST',
      url: '/api/v1/trade/initiate',
      headers: initiateHeaders('initiate-disabled'),
      payload: { quoteId: quote.quoteId, route: 'p2p', recipient: recipient() },
    });
    assert.equal(response.statusCode, 503);
    assert.equal(
      (response.json() as { error: { code: string } }).error.code,
      'PAYOUT_NOT_CONFIGURED',
    );
    await disabled.close();
  });

  it('requires a signed-in user and one idempotency key', async () => {
    const quote = await freshQuote();
    const anonymous = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/initiate',
      payload: { quoteId: quote.quoteId, route: 'p2p', recipient: recipient() },
    });
    assert.equal(anonymous.statusCode, 401);

    const noKey = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/initiate',
      headers: auth(),
      payload: { quoteId: quote.quoteId, route: 'p2p', recipient: recipient() },
    });
    assert.equal(noKey.statusCode, 400);
    assert.equal(
      (noKey.json() as { error: { code: string } }).error.code,
      'IDEMPOTENCY_KEY_REQUIRED',
    );
  });
});

describe('B2.3 payment claim, ledger and cancellation', () => {
  it('confirms a pending collection, posts the deposit and recognises net fee revenue', async () => {
    const quote = await freshQuote();
    const created = await initiate(quote.quoteId, { key: 'claim-confirm' });
    assert.equal(created.statusCode, 201, created.body);
    const body = created.json() as InitiateBody;
    const attempt = await db.pool.query(
      `SELECT external_reference FROM payment_attempts WHERE trade_id = $1`,
      [body.trade.id],
    );
    provider.complete(String(attempt.rows[0]?.['external_reference']), 'SUCCESS');

    const claim = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${body.trade.id}/payment-claim`,
      headers: initiateHeaders('claim-confirm-claim'),
    });
    assert.equal(claim.statusCode, 200, claim.body);
    const claimed = claim.json() as { trade: { status: string }; paymentStatus: string };
    assert.equal(claimed.trade.status, 'escrowed');
    assert.equal(claimed.paymentStatus, 'SUCCESS');

    const journals = await db.pool.query(
      `SELECT t.kind, sum(l.amount_minor)::text AS total, count(*)::int AS lines
       FROM journal_transactions t
       JOIN journal_lines l ON l.transaction_id = t.id
       WHERE t.trade_id = $1
       GROUP BY t.kind
       ORDER BY t.kind`,
      [body.trade.id],
    );
    assert.deepEqual(
      journals.rows.map((row) => [row['kind'], row['total']]),
      [
        ['deposit_received', '0'],
        ['fee_earned', '0'],
      ],
    );

    const netFee = 10_000 - Math.floor(1_010_000 / 200);
    const cash = await db.pool.query(
      `SELECT COALESCE(sum(l.amount_minor), 0)::text AS balance
       FROM journal_lines l
       JOIN journal_transactions t ON t.id = l.transaction_id
       JOIN ledger_accounts a ON a.id = l.account_id
       WHERE a.code = '1000-TZS' AND t.trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(cash.rows[0]?.['balance'], String(1_000_000 + netFee));

    const history = await db.pool.query(
      `SELECT status, actor FROM trade_events WHERE trade_id = $1 ORDER BY id`,
      [body.trade.id],
    );
    assert.deepEqual(
      history.rows.map((row) => [row['status'], row['actor']]),
      [
        ['pending_deposit', 'system'],
        ['escrowed', 'provider'],
      ],
    );

    const replay = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${body.trade.id}/payment-claim`,
      headers: initiateHeaders('claim-confirm-claim'),
    });
    assert.equal(replay.statusCode, 200);
    assert.equal(replay.headers['idempotency-replay'], 'true');
    const journalCount = await db.pool.query(
      `SELECT count(*)::int AS count FROM journal_transactions WHERE trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(journalCount.rows[0]?.['count'], 2);
  });

  it('moves a failed collection to failed without booking money', async () => {
    const quote = await freshQuote();
    const created = await initiate(quote.quoteId, { key: 'claim-failed' });
    const body = created.json() as InitiateBody;
    const attempt = await db.pool.query(
      `SELECT external_reference FROM payment_attempts WHERE trade_id = $1`,
      [body.trade.id],
    );
    provider.complete(String(attempt.rows[0]?.['external_reference']), 'FAILED');

    const claim = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${body.trade.id}/payment-claim`,
      headers: initiateHeaders('claim-failed-claim'),
    });
    assert.equal(claim.statusCode, 200, claim.body);
    assert.equal((claim.json() as { trade: { status: string } }).trade.status, 'failed');

    const journals = await db.pool.query(
      `SELECT count(*)::int AS count FROM journal_transactions WHERE trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(journals.rows[0]?.['count'], 0);
    const attemptState = await db.pool.query(
      `SELECT status FROM payment_attempts WHERE trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(attemptState.rows[0]?.['status'], 'failed');
  });

  it('cancels a pending trade and refuses to cancel once the provider has paid', async () => {
    const cancelQuote = await freshQuote();
    const created = await initiate(cancelQuote.quoteId, { key: 'cancel-pending' });
    const body = created.json() as InitiateBody;

    const cancel = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${body.trade.id}/cancel`,
      headers: initiateHeaders('cancel-pending-action'),
    });
    assert.equal(cancel.statusCode, 200, cancel.body);
    assert.equal((cancel.json() as { trade: { status: string } }).trade.status, 'cancelled');
    const attempt = await db.pool.query(
      `SELECT status FROM payment_attempts WHERE trade_id = $1`,
      [body.trade.id],
    );
    assert.equal(attempt.rows[0]?.['status'], 'expired');

    const paidQuote = await freshQuote();
    const paid = await initiate(paidQuote.quoteId, { key: 'cancel-paid' });
    const paidBody = paid.json() as InitiateBody;
    const paidAttempt = await db.pool.query(
      `SELECT external_reference FROM payment_attempts WHERE trade_id = $1`,
      [paidBody.trade.id],
    );
    provider.complete(String(paidAttempt.rows[0]?.['external_reference']), 'SUCCESS');

    const refused = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${paidBody.trade.id}/cancel`,
      headers: initiateHeaders('cancel-paid-action'),
    });
    assert.equal(refused.statusCode, 409, refused.body);
    const refusedBody = refused.json() as { trade: { status: string }; error: { code: string } };
    assert.equal(refusedBody.error.code, 'ALREADY_PAID');
    assert.equal(refusedBody.trade.status, 'escrowed');

    const deposit = await db.pool.query(
      `SELECT count(*)::int AS count FROM journal_transactions WHERE trade_id = $1`,
      [paidBody.trade.id],
    );
    assert.equal(deposit.rows[0]?.['count'], 2);
  });

  it('does not expose another user\'s trade', async () => {
    const quote = await freshQuote();
    const created = await initiate(quote.quoteId, { key: 'owner-only' });
    const body = created.json() as InitiateBody;

    const other = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${body.trade.id}`,
      headers: auth(otherToken),
    });
    assert.equal(other.statusCode, 404);
    assert.equal((other.json() as { error: { code: string } }).error.code, 'TRADE_NOT_FOUND');

    const otherCancel = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${body.trade.id}/cancel`,
      headers: initiateHeaders('other-cancel', otherToken),
    });
    assert.equal(otherCancel.statusCode, 404);
  });
});
