import { randomBytes } from 'node:crypto';
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
 * Live B2.4 smoke: TZS collection, sandbox FX liquidity, KES mobile-money
 * payout and the two linked single-currency journals.
 *
 * The sandbox is a simulator, so its PSP merchant payable must hold KES before
 * it can pay KES. This script funds that balance with a separate sandbox KES
 * collection, exactly as an unrelated KES pay-in would. Production uses the
 * approved liquidity provider instead; CrossPay never invents a balance.
 *
 *   SANDBOX_API_KEY_CROSSPAY=... npm run smoke:b2.4
 */

const baseUrl = process.env['SANDBOX_BASE_URL'] ?? 'http://127.0.0.1:8080';
const apiKey = process.env['SANDBOX_API_KEY_CROSSPAY'];
if (!apiKey) {
  console.error('SANDBOX_API_KEY_CROSSPAY is required');
  process.exit(1);
}
const sandboxKey: string = apiKey;

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
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

function headers(token: string, idempotencyKey?: string): Record<string, string> {
  const value: Record<string, string> = { authorization: `Bearer ${token}` };
  if (idempotencyKey) value['x-idempotency-key'] = idempotencyKey;
  return value;
}

async function main(): Promise<void> {
  const db = await startTestDatabase();
  let app: FastifyInstance | undefined;
  try {
    const user = await createUser(db.pool, {
      phone: '+255755920002',
      displayName: 'Payout Smoke',
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
      paymentWebhookSecret: null,
      paymentWebhookMaxSkewSeconds: 300,
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
    assert(quoteResponse.statusCode === 200, `quote failed: ${quoteResponse.body}`);
    const quote = quoteResponse.json() as {
      id: string;
      routes: Array<{ route: string; totalDebitMinor: number }>;
    };
    const p2p = quote.routes.find((route) => route.route === 'p2p');
    assert(p2p, 'the sandbox quote has no p2p route');

    const initiateResponse = await app.inject({
      method: 'POST',
      url: '/api/v1/trade/initiate',
      headers: headers(token, `smoke24-initiate-${randomBytes(6).toString('hex')}`),
      payload: {
        quoteId: quote.id,
        route: 'p2p',
        recipient: {
          railId: 'mpesa-ke',
          account: '+254712345678',
          name: 'Payout Smoke Recipient',
          reference: 'SMOKE24',
        },
      },
    });
    assert(initiateResponse.statusCode === 201, `initiate failed: ${initiateResponse.body}`);
    const initiated = initiateResponse.json() as {
      trade: {
        id: string;
        reference: string;
        sendAmountMinor: number;
        feeMinor: number;
        receiveAmountMinor: number;
      };
      collection: { amountMinor: number };
    };

    const attempt = await db.pool.query<{ external_reference: string }>(
      `SELECT external_reference FROM payment_attempts WHERE trade_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [initiated.trade.id],
    );
    const collectionRef = attempt.rows[0]?.external_reference;
    assert(collectionRef, 'no collection reference');

    const collected = (await sandboxPost(
      `/api/sandbox/psp/requests/${encodeURIComponent(collectionRef)}/simulate`,
      { success: true, receipt: `SMOKE24-${Date.now()}` },
      `smoke24-collect-${randomBytes(6).toString('hex')}`,
    )) as { request?: { status?: string; feeMinor?: number } };
    assert(collected.request?.status === 'SUCCESS', 'collection did not succeed');

    const claim = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${initiated.trade.id}/payment-claim`,
      headers: headers(token, `smoke24-claim-${randomBytes(6).toString('hex')}`),
    });
    assert(claim.statusCode === 200, `claim failed: ${claim.body}`);
    assert(
      (claim.json() as { trade: { status: string } }).trade.status === 'escrowed',
      'trade was not escrowed',
    );

    // Fund the sandbox provider's KES payable with an unrelated KES pay-in.
    const fundingAmount = initiated.trade.receiveAmountMinor + 200_000;
    const funding = (await sandboxPost(
      '/api/sandbox/psp/stk-push',
      {
        phoneNumber: '+254712999888',
        amountMinor: fundingAmount,
        currency: 'KES',
        provider: 'MPESA_KE',
        transactionRef: `SMOKE24-FUND-${Date.now()}`,
      },
      `smoke24-fund-${randomBytes(6).toString('hex')}`,
    )) as { request?: { checkoutRequestId?: string; status?: string } };
    assert(funding.request?.checkoutRequestId, 'funding collection was not created');
    const fundingDone = (await sandboxPost(
      `/api/sandbox/psp/requests/${encodeURIComponent(funding.request.checkoutRequestId)}/simulate`,
      { success: true },
      `smoke24-fund-complete-${randomBytes(6).toString('hex')}`,
    )) as { request?: { status?: string } };
    assert(fundingDone.request?.status === 'SUCCESS', 'funding collection did not succeed');

    const disburse = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${initiated.trade.id}/disburse`,
      headers: headers(token, `smoke24-disburse-${randomBytes(6).toString('hex')}`),
    });
    assert(
      disburse.statusCode === 202 || disburse.statusCode === 200,
      `disburse failed: ${disburse.body}`,
    );
    const firstPayout = (disburse.json() as {
      trade: { status: string };
      payout: { status: string; providerReference: string | null };
    }).payout;
    assert(firstPayout.providerReference, 'the provider payout reference is missing');

    const payoutDone = (await sandboxPost(
      `/api/sandbox/psp/payouts/${encodeURIComponent(firstPayout.providerReference)}/simulate`,
      { success: true, receipt: `SMOKE24-OUT-${Date.now()}` },
      `smoke24-payout-${randomBytes(6).toString('hex')}`,
    )) as { payout?: { status?: string } };
    assert(payoutDone.payout?.status === 'SUCCESS', 'payout did not succeed');

    const resume = await app.inject({
      method: 'POST',
      url: `/api/v1/trades/${initiated.trade.id}/disburse`,
      headers: headers(token, `smoke24-resume-${randomBytes(6).toString('hex')}`),
    });
    assert(resume.statusCode === 200, `resume failed: ${resume.body}`);
    const completed = resume.json() as {
      trade: { status: string };
      payout: { status: string };
    };
    assert(completed.trade.status === 'completed', `trade is ${completed.trade.status}`);
    assert(completed.payout.status === 'paid', `payout is ${completed.payout.status}`);

    const journals = await db.pool.query<{
      kind: string;
      currency_code: string;
      balance_minor: string;
    }>(
      `SELECT t.kind, t.currency_code, b.balance_minor::text
       FROM journal_transactions t
       JOIN journal_transaction_balances b ON b.transaction_id = t.id
       WHERE t.trade_id = $1
       ORDER BY t.created_at, t.id`,
      [initiated.trade.id],
    );
    for (const journal of journals.rows) {
      assert(BigInt(journal.balance_minor) === 0n, `${journal.kind} does not balance`);
    }

    const balances = await db.pool.query<{ code: string; balance_minor: string }>(
      `SELECT code, COALESCE(sum(l.amount_minor), 0)::text AS balance_minor
       FROM ledger_accounts a
       LEFT JOIN journal_lines l ON l.account_id = a.id
       JOIN journal_transactions t ON t.id = l.transaction_id AND t.trade_id = $1
       WHERE a.code IN ('1000-TZS', '2000-TZS', '5000-TZS',
                        '5000-KES', '2000-KES', '1000-KES', '3000-TZS')
       GROUP BY a.code
       ORDER BY a.code`,
      [initiated.trade.id],
    );
    const byCode = new Map(balances.rows.map((row) => [row.code, BigInt(row.balance_minor)]));
    assert(byCode.get('2000-TZS') === 0n, 'send-currency payable was not released');
    assert(byCode.get('2000-KES') === 0n, 'payout payable was not released');
    assert(byCode.get('5000-TZS') === -BigInt(initiated.trade.sendAmountMinor), 'FX source is wrong');
    assert(
      byCode.get('5000-KES') === BigInt(initiated.trade.receiveAmountMinor),
      'FX destination is wrong',
    );
    assert(
      byCode.get('1000-KES') === -BigInt(initiated.trade.receiveAmountMinor),
      'payout cash is wrong',
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
            status: completed.trade.status,
          },
          sandbox: {
            collection: collectionRef,
            collectionFeeMinor: collected.request?.feeMinor,
            payout: firstPayout.providerReference,
            fundingMinor: fundingAmount,
          },
          ledger: {
            sendAmountMinor: initiated.trade.sendAmountMinor,
            receiveAmountMinor: initiated.trade.receiveAmountMinor,
            journals: journals.rows.map((row) => `${row.kind}:${row.currency_code}`),
            fxSourceMinor: Number(byCode.get('5000-TZS')),
            fxDestinationMinor: Number(byCode.get('5000-KES')),
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
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
