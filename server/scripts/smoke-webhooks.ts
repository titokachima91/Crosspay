import { randomBytes } from 'node:crypto';
import { createServer } from 'node:net';
import type { FastifyInstance } from 'fastify';
import { startTestDatabase, createUser } from '../test/helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { buildServer } from '../src/http/server.js';
import { signAccessToken } from '../src/http/auth.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { SandboxPricingProvider } from '../src/providers/pricing.js';
import { SandboxPaymentProvider } from '../src/providers/payments.js';

/**
 * Live signed-callback smoke. CrossPay listens on a loopback port, the sandbox
 * signs and delivers real collection and payout webhooks, and the script
 * proves both moved the trade without a manual claim.
 *
 *   SANDBOX_API_KEY_CROSSPAY=... npm run smoke:webhooks
 */

const baseUrl = process.env['SANDBOX_BASE_URL'] ?? 'http://127.0.0.1:8080';
const apiKey = process.env['SANDBOX_API_KEY_CROSSPAY'];
if (!apiKey) {
  console.error('SANDBOX_API_KEY_CROSSPAY is required');
  process.exit(1);
}
const sandboxKey: string = apiKey;
const webhookSecret =
  process.env['PAYMENT_WEBHOOK_SECRET'] ?? 'sandbox_default_webhook_secret';

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address === 'string') {
        server.close();
        reject(new Error('could not allocate a port'));
        return;
      }
      const port = address.port;
      server.close((error) => (error ? reject(error) : resolve(port)));
    });
  });
}

async function sandboxPost(path: string, body: unknown, idempotencyKey: string): Promise<unknown> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': sandboxKey,
      'idempotency-key': idempotencyKey,
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`sandbox ${path} failed: ${response.status} ${text}`);
  return text.length === 0 ? null : (JSON.parse(text) as unknown);
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForTradeStatus(
  app: FastifyInstance,
  token: string,
  tradeId: string,
  expected: string,
  timeoutMs = 15_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    const response = await app.inject({
      method: 'GET',
      url: `/api/v1/trades/${tradeId}`,
      headers: { authorization: `Bearer ${token}` },
    });
    const body = response.json() as { status: string };
    last = body.status;
    if (last === expected) return last;
    await sleep(250);
  }
  throw new Error(`trade stayed ${last}, expected ${expected}`);
}

async function main(): Promise<void> {
  const db = await startTestDatabase();
  let app: FastifyInstance | undefined;
  try {
    const user = await createUser(db.pool, {
      phone: '+255755920003',
      displayName: 'Webhook Smoke',
      kycStatus: 'verified',
      limitCurrency: 'TZS',
    });
    await db.pool.query(
      `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
       VALUES ('starter', 'TZS', 100000000)
       ON CONFLICT (tier_code, currency_code)
       DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
    );

    const port = await freePort();
    const context: AppContext = {
      pool: db.pool,
      crypto: new CryptoBox(randomBytes(32)),
      smsSender: new DisabledSmsSender(),
      pricingProvider: new SandboxPricingProvider({ baseUrl, apiKey: sandboxKey }),
      paymentProvider: new SandboxPaymentProvider({ baseUrl, apiKey: sandboxKey }),
      jwtSecret: randomBytes(32),
      accessTokenTtlSeconds: 900,
      refreshTokenTtlSeconds: 3600,
      idempotencyTtlSeconds: 86_400,
      limitTimezone: 'UTC',
      collectionPushTimeoutSeconds: 120,
      collectionPollIntervalSeconds: 5,
      paymentCallbackUrl: `http://127.0.0.1:${port}/api/v1/webhooks/payments/sandbox`,
      paymentWebhookSecret: Buffer.from(webhookSecret, 'utf8'),
      paymentWebhookMaxSkewSeconds: 300,
    };
    app = await buildServer(context);
    await app.listen({ port, host: '127.0.0.1' });
    const token = await signAccessToken({ userId: user, secret: context.jwtSecret });

    const quote = (
      await app.inject({
        method: 'POST',
        url: '/api/v1/trade/quote',
        headers: { authorization: `Bearer ${token}` },
        payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 1_000_000 },
      })
    ).json() as { id: string };

    const initiated = (
      await app.inject({
        method: 'POST',
        url: '/api/v1/trade/initiate',
        headers: {
          authorization: `Bearer ${token}`,
          'x-idempotency-key': `wh-initiate-${randomBytes(6).toString('hex')}`,
        },
        payload: {
          quoteId: quote.id,
          route: 'p2p',
          recipient: {
            railId: 'mpesa-ke',
            account: '+254712345678',
            name: 'Webhook Smoke Recipient',
            reference: 'WEBHOOK',
          },
        },
      })
    ).json() as {
      trade: { id: string; reference: string; receiveAmountMinor: number };
    };

    const attempt = await db.pool.query<{ external_reference: string }>(
      `SELECT external_reference FROM payment_attempts WHERE trade_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [initiated.trade.id],
    );
    const collectionRef = attempt.rows[0]?.external_reference;
    assert(collectionRef, 'no collection reference');

    // Simulate the payer. The sandbox delivers the signed callback before the
    // simulate response returns, so no manual claim is needed.
    const simulated = (await sandboxPost(
      `/api/sandbox/psp/requests/${encodeURIComponent(collectionRef)}/simulate`,
      { success: true, receipt: `WH-${Date.now()}` },
      `wh-collect-${randomBytes(6).toString('hex')}`,
    )) as { request?: { status?: string } };
    assert(simulated.request?.status === 'SUCCESS', 'collection did not succeed');
    const escrowed = await waitForTradeStatus(app, token, initiated.trade.id, 'escrowed');
    assert(escrowed === 'escrowed', 'callback did not escrow the trade');

    const fundingAmount = initiated.trade.receiveAmountMinor + 200_000;
    const funding = (await sandboxPost(
      '/api/sandbox/psp/stk-push',
      {
        phoneNumber: '+254712999777',
        amountMinor: fundingAmount,
        currency: 'KES',
        provider: 'MPESA_KE',
        transactionRef: `WH-FUND-${Date.now()}`,
      },
      `wh-fund-${randomBytes(6).toString('hex')}`,
    )) as { request?: { checkoutRequestId?: string } };
    assert(funding.request?.checkoutRequestId, 'funding collection was not created');
    await sandboxPost(
      `/api/sandbox/psp/requests/${encodeURIComponent(funding.request.checkoutRequestId)}/simulate`,
      { success: true },
      `wh-fund-complete-${randomBytes(6).toString('hex')}`,
    );

    const disburse = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${initiated.trade.id}/disburse`,
      headers: {
        authorization: `Bearer ${token}`,
        'x-idempotency-key': `wh-disburse-${randomBytes(6).toString('hex')}`,
      },
    });
    assert(
      disburse.statusCode === 202 || disburse.statusCode === 200,
      `disburse failed: ${disburse.body}`,
    );

    // The sandbox payout auto-completes after ~2.5s and calls back.
    const completed = await waitForTradeStatus(app, token, initiated.trade.id, 'completed', 20_000);

    const events = await db.pool.query<{
      event_type: string;
      status: string;
      signature_verified: boolean;
    }>(
      `SELECT event_type, status, signature_verified FROM payment_events
       WHERE trade_id = $1 ORDER BY received_at`,
      [initiated.trade.id],
    );
    assert(events.rowCount === 2, `expected two callbacks, saw ${events.rowCount}`);
    for (const event of events.rows) {
      assert(event.status === 'processed', `${event.event_type} is ${event.status}`);
      assert(event.signature_verified, `${event.event_type} was not signature-verified`);
    }
    assert(
      events.rows.some((event) => event.event_type.startsWith('psp.collection.')),
      'no collection callback was recorded',
    );
    assert(
      events.rows.some((event) => event.event_type.startsWith('psp.payout.')),
      'no payout callback was recorded',
    );

    console.log(
      JSON.stringify(
        {
          ok: true,
          trade: { id: initiated.trade.id, status: completed },
          callbacks: events.rows.map((event) => event.event_type),
          signatureVerified: true,
        },
        null,
        2,
      ),
    );
  } finally {
    await app?.close();
    await db.close();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
