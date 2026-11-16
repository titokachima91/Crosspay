import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { startTestDatabase } from '../test/helpers/test-database.js';
import { createUser } from '../test/helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { buildServer } from '../src/http/server.js';
import { signAccessToken } from '../src/http/auth.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { SandboxPricingProvider } from '../src/providers/pricing.js';
import { SandboxPaymentProvider } from '../src/providers/payments.js';

/**
 * Live B2.3 smoke test against the real kachi-fintech-sandbox provider.
 *
 * This script proves the whole collection path end to end, not with a fake:
 * - a real sandbox pricing quote becomes a CrossPay quote;
 * - `/trade/initiate` starts a real sandbox STK push;
 * - the sandbox operator simulates the payer PIN;
 * - `/trades/:id/payment-claim` re-reads the sandbox and posts the ledger.
 *
 * It uses an ephemeral PostgreSQL instance, so it never touches a hosted DB.
 * Run it while the sandbox is listening, for example:
 *
 *   SANDBOX_API_KEY_CROSSPAY=... npm run smoke:b2.3
 */

const baseUrl = process.env['SANDBOX_BASE_URL'] ?? 'http://127.0.0.1:8080';
const sandboxApiKey = process.env['SANDBOX_API_KEY_CROSSPAY'];
if (!sandboxApiKey) {
  console.error('SANDBOX_API_KEY_CROSSPAY is required');
  process.exit(1);
}
const sandboxKey: string = sandboxApiKey;

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function sandboxPost(path: string, body: unknown, idempotencyKey: string): Promise<unknown> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': sandboxApiKey,
      'idempotency-key': idempotencyKey,
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`sandbox ${path} failed: ${response.status} ${text}`);
  }
  return text.length === 0 ? null : (JSON.parse(text) as unknown);
}

function headers(token: string, idempotencyKey?: string): Record<string, string> {
  const value: Record<string, string> = { authorization: `Bearer ${token}` };
  if (idempotencyKey) value['x-idempotency-key'] = idempotencyKey;
  return value;
}

function codeOf(body: unknown): string {
  return ((body as { error?: { code?: string } } | null)?.error?.code ?? '').toString();
}

async function main(): Promise<void> {
  const db = await startTestDatabase();
  let app: FastifyInstance | undefined;
  try {
    const user = await createUser(db.pool, {
      phone: '+255755920001',
      displayName: 'Live Smoke',
      kycStatus: 'verified',
      limitCurrency: 'TZS',
    });
    await db.pool.query(
      `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
       VALUES ('starter', 'TZS', 100000000)
       ON CONFLICT (tier_code, currency_code)
       DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
    );

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
      paymentCallbackUrl: process.env['SMOKE_CALLBACK_URL'],
      paymentWebhookSecret: process.env['PAYMENT_WEBHOOK_SECRET']
        ? Buffer.from(process.env['PAYMENT_WEBHOOK_SECRET'], 'utf8')
        : null,
      paymentWebhookMaxSkewSeconds: 300,
      p2pEnabled: false,
    };

    app = await buildServer(context);
    await app.ready();
    const token = await signAccessToken({ userId: user, secret: context.jwtSecret });

    const quoteResponse = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/quote',
      headers: headers(token),
      payload: { sendCurrency: 'TZS', receiveCurrency: 'KES', sendAmountMinor: 1_000_000 },
    });
    assert(quoteResponse.statusCode === 201 || quoteResponse.statusCode === 200, `quote failed: ${quoteResponse.body}`);
    const quote = quoteResponse.json() as {
      id: string;
      rate: number;
      routes: Array<{ route: string; feeMinor: number; totalDebitMinor: number }>;
    };
    const p2p = quote.routes.find((route) => route.route === 'p2p');
    assert(p2p, 'the sandbox quote has no p2p route');

    const initiateResponse = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/initiate',
      headers: headers(token, `smoke-initiate-${randomBytes(6).toString('hex')}`),
      payload: {
        quoteId: quote.id,
        route: 'p2p',
        recipient: {
          railId: 'mpesa-ke',
          account: '+254712345678',
          name: 'Live Smoke Recipient',
          reference: 'SMOKE',
        },
      },
    });
    assert(initiateResponse.statusCode === 201, `initiate failed: ${initiateResponse.body}`);
    const initiated = initiateResponse.json() as {
      trade: { id: string; reference: string; status: string; sendAmountMinor: number; feeMinor: number };
      collection: { amountMinor: number; pushSent: boolean; networkName?: string };
    };
    assert(initiated.trade.status === 'pending_deposit', `unexpected trade status ${initiated.trade.status}`);
    assert(initiated.collection.pushSent, 'the sandbox did not report a push');
    assert(initiated.collection.amountMinor === p2p.totalDebitMinor, 'total debit mismatch');

    const attempt = await db.pool.query<{ external_reference: string; provider: string }>(
      `SELECT external_reference, provider
       FROM payment_attempts
       WHERE trade_id = $1
       ORDER BY created_at DESC
       LIMIT 1`,
      [initiated.trade.id],
    );
    const reference = attempt.rows[0]?.external_reference;
    assert(reference, 'no payment attempt was stored');

    const simulated = (await sandboxPost(
      `/api/sandbox/psp/requests/${encodeURIComponent(reference)}/simulate`,
      { success: true, receipt: `SMOKE-${Date.now()}` },
      `smoke-simulate-${randomBytes(6).toString('hex')}`,
    )) as { request?: { status?: string; feeMinor?: number; amountMinor?: number } };
    const sandboxRequest = simulated.request;
    assert(sandboxRequest?.status === 'SUCCESS', `sandbox did not complete: ${JSON.stringify(simulated)}`);
    assert(sandboxRequest.amountMinor === p2p.totalDebitMinor, 'sandbox collected a different amount');
    assert(typeof sandboxRequest.feeMinor === 'number', 'sandbox did not report its fee');

    const claimResponse = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${initiated.trade.id}/payment-claim`,
      headers: headers(token, `smoke-claim-${randomBytes(6).toString('hex')}`),
    });
    assert(claimResponse.statusCode === 200, `claim failed: ${claimResponse.body}`);
    const claimed = claimResponse.json() as {
      trade: { status: string };
      paymentStatus: string;
    };
    assert(claimed.trade.status === 'escrowed', `claim left the trade ${claimed.trade.status}`);
    assert(claimed.paymentStatus === 'SUCCESS', `claim reported ${claimed.paymentStatus}`);

    const journals = await db.pool.query<{ kind: string; balance_minor: string; line_count: number }>(
      `SELECT t.kind, b.balance_minor::text, b.line_count
       FROM journal_transactions t
       JOIN journal_transaction_balances b ON b.transaction_id = t.id
       WHERE t.trade_id = $1
       ORDER BY t.kind`,
      [initiated.trade.id],
    );
    assert(journals.rows.length === 2, `expected deposit + fee journals, saw ${journals.rows.length}`);
    for (const journal of journals.rows) {
      assert(BigInt(journal.balance_minor) === 0n, `${journal.kind} is not balanced`);
      assert(journal.line_count === 2, `${journal.kind} does not have two lines`);
    }

    const balances = await db.pool.query<{ code: string; balance_minor: string }>(
      `SELECT code, balance_minor::text
       FROM ledger_account_balances
       WHERE code IN ('1000-TZS', '2000-TZS', '3000-TZS')
       ORDER BY code`,
    );
    const byCode = new Map(balances.rows.map((row) => [row.code, BigInt(row.balance_minor)]));
    const providerFee = BigInt(sandboxRequest.feeMinor ?? 0);
    const sendAmount = BigInt(initiated.trade.sendAmountMinor);
    const platformFee = BigInt(initiated.trade.feeMinor);
    const netFee = platformFee - providerFee;

    assert(
      (byCode.get('2000-TZS') ?? 1n) === -sendAmount,
      'trade payable does not equal the principal',
    );
    assert(
      (byCode.get('3000-TZS') ?? 1n) === -netFee,
      'fee revenue does not equal the net platform fee',
    );
    assert(
      (byCode.get('1000-TZS') ?? -1n) === sendAmount + netFee,
      'partner cash does not equal principal plus net fee',
    );

    const imbalance = await db.pool.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM journal_transaction_balances WHERE balance_minor <> 0`,
    );
    assert(imbalance.rows[0]?.count === '0', 'the ledger has an unbalanced transaction');

    console.log(
      JSON.stringify(
        {
          ok: true,
          trade: {
            id: initiated.trade.id,
            reference: initiated.trade.reference,
            status: claimed.trade.status,
          },
          sandbox: {
            checkoutRequestId: reference,
            provider: attempt.rows[0]?.provider,
            collectedMinor: sandboxRequest.amountMinor,
            providerFeeMinor: Number(providerFee),
          },
          ledger: {
            sendAmountMinor: Number(sendAmount),
            platformFeeMinor: Number(platformFee),
            netFeeMinor: Number(netFee),
            cashMinor: Number(byCode.get('1000-TZS')),
            payableMinor: Number(byCode.get('2000-TZS')),
            feeRevenueMinor: Number(byCode.get('3000-TZS')),
          },
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
  console.error(codeOf(error) || error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
