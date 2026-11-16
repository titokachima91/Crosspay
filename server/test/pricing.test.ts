import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { createUser, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { signAccessToken } from '../src/http/auth.js';
import { buildServer } from '../src/http/server.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import {
  DisabledPricingProvider,
  PricingRejectedError,
  PricingUnavailableError,
  type PricingEstimate,
  type PricingProvider,
  type PricingQuote,
  type RatesPayload,
} from '../src/providers/pricing.js';
import { DisabledPaymentProvider } from '../src/providers/payments.js';

type StubMode = 'ok' | 'reject' | 'down' | 'invalid';

class StubPricingProvider implements PricingProvider {
  readonly name = 'stub';
  mode: StubMode = 'ok';
  quotes = 0;
  estimates = 0;

  rates(): Promise<RatesPayload> {
    return Promise.resolve({
      rates: [{ from: 'TZS', to: 'KES', rate: 17.5, status: { code: 'active_clearing', level: 'healthy' } }],
    });
  }

  estimate(input: { sendAmountMinor: number }): Promise<PricingEstimate> {
    this.estimates += 1;
    if (this.mode === 'down') {
      return Promise.reject(new PricingUnavailableError('PRICING_UNAVAILABLE', 'stub down'));
    }
    return Promise.resolve({
      rate: 17.5,
      receiveAmountMinor: this.receiveMinor(input.sendAmountMinor),
      estimatedMinSeconds: 20,
      estimatedMaxSeconds: 60,
      route: 'p2p',
    });
  }

  quote(input: { sendAmountMinor: number }): Promise<PricingQuote> {
    this.quotes += 1;
    if (this.mode === 'down') {
      return Promise.reject(new PricingUnavailableError('PRICING_UNAVAILABLE', 'stub down'));
    }
    if (this.mode === 'reject') {
      return Promise.reject(
        new PricingRejectedError(422, 'CORRIDOR_UNAVAILABLE', 'No rate for this corridor'),
      );
    }
    if (this.mode === 'invalid') {
      return Promise.resolve({ rate: 0 } as PricingQuote);
    }

    const feeMinor = Math.floor((input.sendAmountMinor * 150) / 10_000);
    const quotedAt = new Date();
    const expiresAt = new Date(quotedAt.getTime() + 5 * 60 * 1000);
    return Promise.resolve({
      rate: 17.5,
      quotedAt: quotedAt.toISOString(),
      expiresAt: expiresAt.toISOString(),
      routes: [
        {
          route: 'p2p',
          feeBps: 150,
          feeMinor,
          payoutMinor: this.receiveMinor(input.sendAmountMinor),
          totalDebitMinor: input.sendAmountMinor + feeMinor,
          estimatedMinSeconds: 20,
          estimatedMaxSeconds: 60,
          isRecommended: true,
          isAvailable: true,
          status: { code: 'active_clearing', level: 'healthy' },
          breakdown: [{ code: 'platform_fee', amountMinor: feeMinor }],
        },
        {
          route: 'bank',
          feeBps: 150,
          feeMinor,
          payoutMinor: this.receiveMinor(input.sendAmountMinor),
          totalDebitMinor: input.sendAmountMinor + feeMinor,
          estimatedMinSeconds: 900,
          estimatedMaxSeconds: 1_800,
          isRecommended: false,
          isAvailable: true,
          status: { code: 'active_clearing', level: 'healthy' },
          breakdown: [{ code: 'platform_fee', amountMinor: feeMinor }],
        },
      ],
    });
  }

  private receiveMinor(sendAmountMinor: number): number {
    return Math.floor((sendAmountMinor / 17.5) * 100);
  }
}

let db: TestDatabase;
let app: FastifyInstance;
let provider: StubPricingProvider;
let context: AppContext;
let verifiedUser: string;
let pendingUser: string;
let usdUser: string;
let verifiedToken: string;
let pendingToken: string;
let usdToken: string;

before(async () => {
  db = await startTestDatabase();
  provider = new StubPricingProvider();
  context = {
    pool: db.pool,
    crypto: new CryptoBox(randomBytes(32)),
    smsSender: new DisabledSmsSender(),
    pricingProvider: provider,
    paymentProvider: new DisabledPaymentProvider(),
    jwtSecret: randomBytes(32),
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 3600,
    idempotencyTtlSeconds: 86_400,
    limitTimezone: 'UTC',
    collectionPushTimeoutSeconds: 120,
    collectionPollIntervalSeconds: 5,
    paymentWebhookSecret: null,
    paymentWebhookMaxSkewSeconds: 300,
    p2pEnabled: false,
  };

  verifiedUser = await createUser(db.pool, {
    phone: '+255755900001',
    displayName: 'Verified Trader',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  pendingUser = await createUser(db.pool, {
    phone: '+255755900002',
    displayName: 'Pending Trader',
    kycStatus: 'pending',
  });
  usdUser = await createUser(db.pool, {
    phone: '+255755900003',
    displayName: 'USD Trader',
    kycStatus: 'verified',
    limitCurrency: 'USD',
  });

  await db.pool.query(
    `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
     VALUES ('starter', 'TZS', 10000000)
     ON CONFLICT (tier_code, currency_code)
     DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
  );

  verifiedToken = await signAccessToken({ userId: verifiedUser, secret: context.jwtSecret });
  pendingToken = await signAccessToken({ userId: pendingUser, secret: context.jwtSecret });
  usdToken = await signAccessToken({ userId: usdUser, secret: context.jwtSecret });

  app = await buildServer(context);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

function auth(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

async function quoteCount(): Promise<number> {
  const result = await db.pool.query<{ count: string }>('SELECT count(*)::text AS count FROM quotes');
  return Number(result.rows[0]?.['count'] ?? 0);
}

describe('B2.2 pricing, estimate and quote', () => {
  it('serves the provider rates and keeps the disabled default honest', async () => {
    const rates = await app.inject({ method: 'GET', url: '/api/v1/rates' });
    assert.equal(rates.statusCode, 200);
    const body = rates.json() as { rates: Array<{ from: string; to: string; rate: number }> };
    assert.equal(body.rates.length, 1);
    assert.equal(body.rates[0]?.from, 'TZS');
    assert.equal(body.rates[0]?.to, 'KES');

    const disabled = await buildServer({ ...context, pricingProvider: new DisabledPricingProvider() });
    const unavailable = await disabled.inject({ method: 'GET', url: '/api/v1/rates' });
    assert.equal(unavailable.statusCode, 503);
    assert.equal(
      (unavailable.json() as { error: { code: string } }).error.code,
      'PRICING_NOT_CONFIGURED',
    );
    await disabled.close();
  });

  it('returns an indicative estimate for a signed-in user', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/trade/estimate?sendCurrency=TZS&receiveCurrency=KES&sendAmountMinor=1000000',
      headers: auth(verifiedToken),
    });
    assert.equal(response.statusCode, 200);
    const body = response.json() as {
      rate: number;
      receiveAmountMinor: number;
      estimatedMinSeconds: number;
      estimatedMaxSeconds: number;
      route: string;
    };
    assert.equal(body.rate, 17.5);
    assert.equal(body.receiveAmountMinor, 5_714_285);
    assert.equal(body.route, 'p2p');
    assert.ok(body.estimatedMaxSeconds >= body.estimatedMinSeconds);

    const anonymous = await app.inject({
      method: 'GET',
      url: '/api/v1/trade/estimate?sendCurrency=TZS&receiveCurrency=KES&sendAmountMinor=1000000',
    });
    assert.equal(anonymous.statusCode, 401);
  });

  it('locks and persists a quote with the provider route snapshot', async () => {
    const before = await quoteCount();
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 1_000_000 },
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as {
      id: string;
      rate: number;
      serverTime: string;
      expiresAt: string;
      routes: Array<{
        route: string;
        feeBps: number;
        feeMinor: number;
        payoutMinor: number;
        totalDebitMinor: number;
        isRecommended: boolean;
        isAvailable: boolean;
        breakdown: Array<{ code: string; amountMinor: number }>;
      }>;
    };
    assert.match(body.id, /^[0-9a-f-]{36}$/);
    assert.equal(body.rate, 17.5);
    assert.ok(Date.parse(body.expiresAt) > Date.parse(body.serverTime));
    assert.equal(body.routes.length, 2);
    assert.equal(body.routes.filter((route) => route.isRecommended).length, 1);

    const p2p = body.routes.find((route) => route.route === 'p2p');
    assert.ok(p2p);
    assert.equal(p2p.feeBps, 150);
    assert.equal(p2p.feeMinor, 15_000);
    assert.equal(p2p.totalDebitMinor, 1_015_000);
    assert.equal(p2p.payoutMinor, 5_714_285);
    assert.deepEqual(p2p.breakdown, [{ code: 'platform_fee', amountMinor: 15_000 }]);

    assert.equal(await quoteCount(), before + 1);
    const stored = await db.pool.query<{
      send_amount_minor: string;
      rate: string;
      status: string;
      expires_at: Date;
    }>('SELECT send_amount_minor, rate, status, expires_at FROM quotes WHERE id = $1', [body.id]);
    assert.equal(stored.rows[0]?.send_amount_minor, '1000000');
    assert.equal(stored.rows[0]?.status, 'active');
    assert.equal(Number(stored.rows[0]?.rate), 17.5);

    const routes = await db.pool.query<{ route: string; fee_minor: string }>(
      'SELECT route, fee_minor FROM quote_routes WHERE quote_id = $1 ORDER BY route',
      [body.id],
    );
    assert.deepEqual(routes.rows.map((row) => row.route), ['bank', 'p2p']);
  });

  it('rejects unverified, over-limit and unapproved corridors without storing a quote', async () => {
    const before = await quoteCount();

    const pending = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(pendingToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 100_000 },
    });
    assert.equal(pending.statusCode, 403);
    assert.equal(
      (pending.json() as { error: { code: string } }).error.code,
      'VERIFICATION_REQUIRED',
    );

    const overLimit = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 20_000_000 },
    });
    assert.equal(overLimit.statusCode, 422);
    assert.equal(
      (overLimit.json() as { error: { code: string } }).error.code,
      'LIMIT_EXCEEDED',
    );

    const noLimit = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(usdToken),
      payload: { sendCurrency: 'USD', receiveCurrency: 'KES', sendAmountMinor: 10_000 },
    });
    assert.equal(noLimit.statusCode, 422);
    assert.equal(
      (noLimit.json() as { error: { code: string } }).error.code,
      'LIMIT_EXCEEDED',
    );

    const unknownCurrency = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'XXX', receiveCurrency: 'KES', sendAmountMinor: 10_000 },
    });
    assert.equal(unknownCurrency.statusCode, 422);
    assert.equal(
      (unknownCurrency.json() as { error: { code: string } }).error.code,
      'VALIDATION_FAILED',
    );

    const sameCurrency = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'TZS', sendAmountMinor: 10_000 },
    });
    assert.equal(sameCurrency.statusCode, 400);

    assert.equal(await quoteCount(), before);
  });

  it('maps provider rejection, outage and invalid data to honest errors', async () => {
    provider.mode = 'reject';
    const rejected = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 100_000 },
    });
    assert.equal(rejected.statusCode, 422);
    assert.equal(
      (rejected.json() as { error: { code: string } }).error.code,
      'CORRIDOR_UNAVAILABLE',
    );

    provider.mode = 'down';
    const down = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 100_000 },
    });
    assert.equal(down.statusCode, 503);
    assert.equal(
      (down.json() as { error: { code: string } }).error.code,
      'PRICING_UNAVAILABLE',
    );

    provider.mode = 'invalid';
    const invalid = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: auth(verifiedToken),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 100_000 },
    });
    assert.equal(invalid.statusCode, 503);
    assert.equal(
      (invalid.json() as { error: { code: string } }).error.code,
      'PRICING_UNAVAILABLE',
    );

    provider.mode = 'ok';
  });
});
