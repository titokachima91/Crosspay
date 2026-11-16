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
let noLinkApp: FastifyInstance;
let context: AppContext;
let user: string;
let token: string;

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
    p2pEnabled: true,
    publicApiUrl: 'https://api.crosspay.test',
  };
  user = await createUser(db.pool, {
    phone: '+255755960001',
    displayName: 'Insights User',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  token = await signAccessToken({ userId: user, secret: context.jwtSecret });

  await db.pool.query(
    `INSERT INTO p2p_corridors
       (send_currency, receive_currency, enabled, exposure_cap_minor,
        match_deadline_seconds, spread_bps, estimated_settle_seconds)
     VALUES ('TZS', 'KES', true, 1000000000, 600, 50, 120),
            ('KES', 'TZS', false, 1000000000, 600, 50, 90)`,
  );

  const kesQuote = await createQuote(db.pool, user, {
    sendCurrency: 'KES',
    receiveCurrency: 'TZS',
  });

  const addTrade = async (
    quote: Awaited<ReturnType<typeof createQuote>>,
    input: {
      status: string;
      sendAmountMinor: bigint;
      receiveAmountMinor: bigint;
      reference: string;
      sendCurrency?: string;
      receiveCurrency?: string;
    },
  ): Promise<void> => {
    await insertTrade(db.pool, {
      userId: user,
      quote,
      status: input.status,
      sendAmountMinor: input.sendAmountMinor,
      receiveAmountMinor: input.receiveAmountMinor,
      reference: input.reference,
      sendCurrency: input.sendCurrency,
      receiveCurrency: input.receiveCurrency,
    });
  };

  const extraTzsQuotes = await Promise.all([
    createQuote(db.pool, user),
    createQuote(db.pool, user),
    createQuote(db.pool, user),
    createQuote(db.pool, user),
    createQuote(db.pool, user),
  ]);
  const [q1, q2, q3, q4, q5] = extraTzsQuotes;
  assert.ok(q1 && q2 && q3 && q4 && q5);

  await addTrade(q1, {
    status: 'escrowed',
    sendAmountMinor: 1_000_000n,
    receiveAmountMinor: 54_054n,
    reference: 'CP-INSIGHT001',
  });
  await addTrade(q2, {
    status: 'matching',
    sendAmountMinor: 500_000n,
    receiveAmountMinor: 27_027n,
    reference: 'CP-INSIGHT002',
  });
  await addTrade(q3, {
    status: 'completed',
    sendAmountMinor: 500_000n,
    receiveAmountMinor: 27_027n,
    reference: 'CP-INSIGHT003',
  });
  await addTrade(q4, {
    status: 'completed',
    sendAmountMinor: 600_000n,
    receiveAmountMinor: 32_432n,
    reference: 'CP-INSIGHT004',
  });
  await addTrade(q5, {
    status: 'failed',
    sendAmountMinor: 999_999n,
    receiveAmountMinor: 54_054n,
    reference: 'CP-INSIGHT005',
  });
  await addTrade(kesQuote, {
    status: 'completed',
    sendCurrency: 'KES',
    receiveCurrency: 'TZS',
    sendAmountMinor: 55_000n,
    receiveAmountMinor: 1_000_000n,
    reference: 'CP-INSIGHT006',
  });

  app = await buildServer(context);
  await app.ready();
  noLinkApp = await buildServer({ ...context, publicApiUrl: undefined });
  await noLinkApp.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await noLinkApp.close();
  await db.close();
});

function auth(): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

describe('market depth, analytics and export', () => {
  it('reports real queue depth only for corridors with an approved estimate', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/market/depth',
      headers: auth(),
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as {
      corridors: Array<{
        from: string;
        to: string;
        queueDepth: number;
        estimatedSettleSeconds: number;
      }>;
    };
    assert.deepEqual(body.corridors, [
      {
        from: 'TZS',
        to: 'KES',
        queueDepth: 2,
        estimatedSettleSeconds: 120,
      },
    ]);

    const anonymous = await app.inject({ method: 'GET', url: '/api/v1/market/depth' });
    assert.equal(anonymous.statusCode, 401);
  });

  it('aggregates only completed trades in the user primary currency', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/trades/analytics',
      headers: auth(),
    });
    assert.equal(response.statusCode, 200, response.body);
    const body = response.json() as {
      totals: {
        trades: number;
        sentMinor: number;
        sentCurrency: string;
        receivedMinor: number;
        receivedCurrency: string;
      };
      corridors: Array<{ from: string; to: string; trades: number; sentMinor: number }>;
    };
    assert.deepEqual(body.totals, {
      trades: 2,
      sentMinor: 1_100_000,
      sentCurrency: 'TZS',
      receivedMinor: 59_459,
      receivedCurrency: 'KES',
    });
    assert.deepEqual(body.corridors, [
      { from: 'TZS', to: 'KES', trades: 2, sentMinor: 1_100_000 },
    ]);
  });

  it('issues a short-lived server-built CSV link and serves only that user', async () => {
    const ticket = await app.inject({
      method: 'GET',
      url: '/api/v1/trades/export',
      headers: auth(),
    });
    assert.equal(ticket.statusCode, 200, ticket.body);
    const body = ticket.json() as { downloadUrl: string; expiresAt: string };
    assert.match(body.downloadUrl, /^https:\/\/api\.crosspay\.test\/api\/v1\/trades\/export\/download\?token=/);
    assert.ok(new Date(body.expiresAt).getTime() > Date.now());

    const download = await app.inject({
      method: 'GET',
      url: new URL(body.downloadUrl).pathname + new URL(body.downloadUrl).search,
    });
    assert.equal(download.statusCode, 200, download.body);
    assert.match(download.headers['content-type'] as string, /text\/csv/);
    const lines = download.body.trim().split('\n');
    assert.equal(
      lines[0],
      'reference,created_at,status,route,send_currency,send_amount_minor,fee_minor,receive_currency,receive_amount_minor,rate,beneficiary_name',
    );
    assert.equal(lines.length, 7);
    assert.ok(download.body.includes('CP-INSIGHT003'));
    assert.ok(!download.body.includes('someone-else'));

    const invalid = await app.inject({
      method: 'GET',
      url: '/api/v1/trades/export/download?token=not-a-token',
    });
    assert.equal(invalid.statusCode, 401);
    assert.equal(
      (invalid.json() as { error: { code: string } }).error.code,
      'EXPORT_LINK_INVALID',
    );
  });

  it('keeps export honest when no public URL is configured', async () => {
    const response = await noLinkApp.inject({
      method: 'GET',
      url: '/api/v1/trades/export',
      headers: auth(),
    });
    assert.equal(response.statusCode, 503);
    assert.equal(
      (response.json() as { error: { code: string } }).error.code,
      'EXPORT_NOT_CONFIGURED',
    );
  });
});
