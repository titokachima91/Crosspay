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
import { DisabledPaymentProvider } from '../src/providers/payments.js';

let db: TestDatabase;
let app: FastifyInstance;
let context: AppContext;
let user: string;
let otherUser: string;
let token: string;
let otherToken: string;

before(async () => {
  db = await startTestDatabase();
  context = {
    pool: db.pool,
    crypto: new CryptoBox(randomBytes(32)),
    smsSender: new DisabledSmsSender(),
    pricingProvider: new DisabledPricingProvider(),
    paymentProvider: new DisabledPaymentProvider(),
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
    publicApiUrl: 'https://api.crosspay.test',
  };
  user = await createUser(db.pool, {
    phone: '+255755920001',
    displayName: 'Invoice Owner',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  otherUser = await createUser(db.pool, {
    phone: '+255755920002',
    displayName: 'Other Customer',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  token = await signAccessToken({ userId: user, secret: context.jwtSecret });
  otherToken = await signAccessToken({ userId: otherUser, secret: context.jwtSecret });
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

async function newTrade(status = 'pending_deposit'): Promise<string> {
  const quote = await createQuote(db.pool, user);
  return insertTrade(db.pool, { userId: user, quote, status });
}

function tokenFrom(shareUrl: string): string {
  const match = /\/pay\/([^/?#]+)$/.exec(shareUrl);
  assert.ok(match, `unexpected share URL ${shareUrl}`);
  return match[1]!;
}

describe('trade invoices and share links', () => {
  it('issues one stable invoice and serves a public payer page and QR image', async () => {
    const tradeId = await newTrade();

    const first = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}/invoice`,
      headers: auth(),
    });
    assert.equal(first.statusCode, 200, first.body);
    const invoice = first.json() as {
      tradeId: string;
      qrCodeUrl: string;
      shareUrl: string;
      validUntil: string;
      amountMinor: number;
      currency: string;
    };
    assert.equal(invoice.tradeId, tradeId);
    assert.equal(invoice.amountMinor, 1_010_000);
    assert.equal(invoice.currency, 'TZS');
    assert.match(invoice.qrCodeUrl, /^https:\/\/api\.crosspay\.test\/api\/v1\/invoices\/.+\/qr\.png$/);
    assert.match(invoice.shareUrl, /^https:\/\/api\.crosspay\.test\/pay\/.+/);
    assert.ok(Date.parse(invoice.validUntil) > Date.now());

    const second = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}/invoice`,
      headers: auth(),
    });
    assert.equal(second.statusCode, 200, second.body);
    assert.equal((second.json() as { shareUrl: string }).shareUrl, invoice.shareUrl);

    const shared = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${tradeId}/share`,
      headers: { ...auth(), 'x-idempotency-key': 'invoice-share-key' },
      payload: {},
    });
    assert.equal(shared.statusCode, 200, shared.body);
    const shareBody = shared.json() as { shareUrl: string; validUntil: string };
    assert.equal(shareBody.shareUrl, invoice.shareUrl);
    assert.equal(shareBody.validUntil, invoice.validUntil);

    const replay = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${tradeId}/share`,
      headers: { ...auth(), 'x-idempotency-key': 'invoice-share-key' },
      payload: {},
    });
    assert.equal(replay.statusCode, 200, replay.body);
    assert.equal((replay.json() as { shareUrl: string }).shareUrl, invoice.shareUrl);

    const token = tokenFrom(invoice.shareUrl);
    const page = await app.inject({ method: 'GET', url: `/pay/${token}` });
    assert.equal(page.statusCode, 200, page.body);
    assert.match(page.body, /CrossPay/);
    assert.match(page.body, /1,010,000 TZS/);
    assert.match(page.body, /pending deposit/);

    const qr = await app.inject({ method: 'GET', url: `/api/v1/invoices/${token}/qr.png` });
    assert.equal(qr.statusCode, 200, qr.body);
    assert.match(String(qr.headers['content-type']), /^image\/png/);
    assert.ok(qr.rawPayload.length > 100);
  });

  it('hides another customer’s invoice and refuses terminal trades', async () => {
    const tradeId = await newTrade();

    const other = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}/invoice`,
      headers: auth(otherToken),
    });
    assert.equal(other.statusCode, 404);
    assert.equal((other.json() as { error: { code: string } }).error.code, 'TRADE_NOT_FOUND');

    const cancelled = await newTrade('cancelled');
    const refused = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${cancelled}/invoice`,
      headers: auth(),
    });
    assert.equal(refused.statusCode, 409);
    assert.equal((refused.json() as { error: { code: string } }).error.code, 'INVOICE_NOT_AVAILABLE');
  });

  it('expires the link instead of extending it', async () => {
    const tradeId = await newTrade();
    const issued = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}/invoice`,
      headers: auth(),
    });
    const invoice = issued.json() as { shareUrl: string };
    await db.pool.query(
      `UPDATE trade_invoices
       SET created_at = now() - interval '2 hours',
           valid_until = now() - interval '1 minute'
       WHERE trade_id = $1`,
      [tradeId],
    );

    const expired = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}/invoice`,
      headers: auth(),
    });
    assert.equal(expired.statusCode, 410);
    assert.equal((expired.json() as { error: { code: string } }).error.code, 'INVOICE_EXPIRED');

    const token = tokenFrom(invoice.shareUrl);
    const page = await app.inject({ method: 'GET', url: `/pay/${token}` });
    assert.equal(page.statusCode, 200);
    assert.match(page.body, /This invoice has expired/);
    const qr = await app.inject({ method: 'GET', url: `/api/v1/invoices/${token}/qr.png` });
    assert.equal(qr.statusCode, 410);
  });

  it('requires an idempotency key on share', async () => {
    const tradeId = await newTrade();
    const response = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${tradeId}/share`,
      headers: auth(),
      payload: {},
    });
    assert.equal(response.statusCode, 400);
    assert.equal(
      (response.json() as { error: { code: string } }).error.code,
      'IDEMPOTENCY_KEY_REQUIRED',
    );
  });
});
