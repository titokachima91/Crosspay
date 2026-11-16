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
 * Live B4 smoke: two real sandbox-funded trades in opposite directions match,
 * both payouts are simulated by the provider, and the match releases.
 *
 * Each side funds the other's payout: A's TZS collection pays B's TZS
 * recipient, B's KES collection pays A's KES recipient. No extra liquidity is
 * invented.
 *
 *   SANDBOX_API_KEY_CROSSPAY=... npm run smoke:b4
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

interface TradeSetup {
  token: string;
  userId: string;
  phone: string;
  displayName: string;
  limitCurrency: string;
  sendCurrency: string;
  receiveCurrency: string;
  sendAmountMinor: number;
  railId: string;
  account: string;
  key: string;
}

async function main(): Promise<void> {
  const db = await startTestDatabase();
  let app: FastifyInstance | undefined;
  try {
    const users: TradeSetup[] = [
      {
        token: '',
        userId: '',
        phone: '+255755920011',
        displayName: 'P2P TZS',
        limitCurrency: 'TZS',
        sendCurrency: 'TZS',
        receiveCurrency: 'KES',
        sendAmountMinor: 1_000_000,
        railId: 'mpesa-ke',
        account: '+254712345678',
        key: 'a',
      },
      {
        token: '',
        userId: '',
        phone: '+254712920012',
        displayName: 'P2P KES',
        limitCurrency: 'KES',
        sendCurrency: 'KES',
        receiveCurrency: 'TZS',
        sendAmountMinor: 5_714_300,
        railId: 'mpesa-tz',
        account: '+255712345678',
        key: 'b',
      },
    ];

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
      p2pEnabled: true,
    };
    app = await buildServer(context);
    await app.ready();
    const server = app;

    await db.pool.query(
      `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
       VALUES ('starter', 'TZS', 100000000), ('starter', 'KES', 100000000)
       ON CONFLICT (tier_code, currency_code)
       DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
    );
    await db.pool.query(
      `INSERT INTO p2p_corridors
         (send_currency, receive_currency, enabled, exposure_cap_minor,
          match_deadline_seconds, spread_bps)
       VALUES ('TZS', 'KES', true, 1000000000, 600, 50),
              ('KES', 'TZS', true, 1000000000, 600, 50)`,
    );

    for (const user of users) {
      user.userId = await createUser(db.pool, {
        phone: user.phone,
        displayName: user.displayName,
        kycStatus: 'verified',
        limitCurrency: user.limitCurrency,
      });
      user.token = await signAccessToken({ userId: user.userId, secret: context.jwtSecret });
    }

    const trades: Array<{
      id: string;
      reference: string;
      receiveAmountMinor: number;
      collectionRef: string;
    }> = [];

    for (const user of users) {
      const quoteResponse = await app.inject({
        method: 'POST',
        url: '/api/v1/trade/quote',
        headers: headers(user.token),
        payload: {
          sendCurrency: user.sendCurrency,
          receiveCurrency: user.receiveCurrency,
          sendAmountMinor: user.sendAmountMinor,
        },
      });
      assert(quoteResponse.statusCode === 200, `quote ${user.key} failed: ${quoteResponse.body}`);
      const quote = quoteResponse.json() as {
        id: string;
        routes: Array<{ route: string; payoutMinor: number }>;
      };
      const p2p = quote.routes.find((route) => route.route === 'p2p');
      assert(p2p, `no p2p route for ${user.key}`);

      // The sandbox publishes a reciprocal mid-rate, so two customers cannot
      // both cover each other's full payout by a few minor units. A real
      // platform quote keeps a spread; this test-only adjustment makes that
      // spread explicit so the matching saga can be exercised. Pricing spread
      // policy is not built yet.
      const spreadMinor = 1_000;
      await db.pool.query(
        `UPDATE quote_routes SET payout_minor = payout_minor - $2
         WHERE quote_id = $1 AND route = 'p2p'`,
        [quote.id, spreadMinor],
      );
      const payoutMinor = p2p.payoutMinor - spreadMinor;

      const initiated = await app.inject({
        method: 'POST',
        url: '/api/v1/trade/initiate',
        headers: headers(user.token, `smoke4-initiate-${user.key}-${randomBytes(5).toString('hex')}`),
        payload: {
          quoteId: quote.id,
          route: 'p2p',
          recipient: {
            railId: user.railId,
            account: user.account,
            name: `P2P ${user.key}`,
            reference: 'SMOKE4',
          },
        },
      });
      assert(initiated.statusCode === 201, `initiate ${user.key} failed: ${initiated.body}`);
      const body = initiated.json() as {
        trade: { id: string; reference: string };
      };
      const attempt = await db.pool.query<{ external_reference: string }>(
        `SELECT external_reference FROM payment_attempts WHERE trade_id = $1
         ORDER BY created_at DESC LIMIT 1`,
        [body.trade.id],
      );
      const collectionRef = attempt.rows[0]?.external_reference;
      assert(collectionRef, `no collection for ${user.key}`);

      const simulated = (await sandboxPost(
        `/api/sandbox/psp/requests/${encodeURIComponent(collectionRef)}/simulate`,
        { success: true, receipt: `SMOKE4-${user.key}-${Date.now()}` },
        `smoke4-collect-${user.key}-${randomBytes(5).toString('hex')}`,
      )) as { request?: { status?: string; feeMinor?: number } };
      assert(simulated.request?.status === 'SUCCESS', `collection ${user.key} failed`);

      const claim = await app.inject({
        method: 'POST',
        url: `/api/v1/trades/${body.trade.id}/payment-claim`,
        headers: headers(user.token, `smoke4-claim-${user.key}-${randomBytes(5).toString('hex')}`),
      });
      assert(claim.statusCode === 200, `claim ${user.key} failed: ${claim.body}`);
      const claimed = claim.json() as { trade: { status: string } };
      assert(
        ['escrowed', 'matching', 'matched'].includes(claimed.trade.status),
        `claim ${user.key} left ${claimed.trade.status}`,
      );

      trades.push({
        id: body.trade.id,
        reference: body.trade.reference,
        receiveAmountMinor: payoutMinor,
        collectionRef,
      });
    }

    const matchRow = await db.pool.query<{ id: string; status: string }>(
      `SELECT id, status FROM p2p_matches ORDER BY created_at DESC LIMIT 1`,
    );
    const matchId = matchRow.rows[0]?.id;
    assert(matchId, 'the opposite trades did not match');
    assert(matchRow.rows[0]?.status === 'locked', `match is ${matchRow.rows[0]?.status}`);

    const statuses = await db.pool.query<{ id: string; status: string }>(
      `SELECT id, status FROM trades WHERE id IN ($1, $2) ORDER BY created_at`,
      [trades[0]?.id, trades[1]?.id],
    );
    assert(
      statuses.rows.every((row) => row.status === 'matched'),
      `trades are ${statuses.rows.map((row) => row.status).join(',')}`,
    );

    const simulatePayout = async (tradeId: string): Promise<void> => {
      const payout = await db.pool.query<{ provider_reference: string | null }>(
        `SELECT provider_reference FROM payouts WHERE trade_id = $1
         ORDER BY created_at DESC LIMIT 1`,
        [tradeId],
      );
      const providerReference = payout.rows[0]?.provider_reference;
      assert(providerReference, 'no provider payout reference');
      const done = (await sandboxPost(
        `/api/sandbox/psp/payouts/${encodeURIComponent(providerReference)}/simulate`,
        { success: true, receipt: `SMOKE4-OUT-${Date.now()}` },
        `smoke4-payout-${randomBytes(5).toString('hex')}`,
      )) as { payout?: { status?: string } };
      assert(done.payout?.status === 'SUCCESS', 'payout simulation did not succeed');
    };

    const disburse = async (key: string) => {
      const response = await server.inject({
        method: 'POST',
        url: `/api/v1/matches/${matchId}/disburse`,
        headers: headers(users[0]!.token, `smoke4-disburse-${key}-${randomBytes(5).toString('hex')}`),
      });
      assert(response.statusCode === 200, `disburse ${key} failed: ${response.body}`);
      return response.json() as {
        match: { status: string };
        legs: Array<{ trade: { status: string }; payout: { status: string } }>;
      };
    };

    const first = await disburse('1');
    assert(first.match.status === 'locked', 'first leg should leave the match locked');
    assert(first.legs[0]?.payout.status === 'submitted', 'first payout should be submitted');
    await simulatePayout(trades[0]!.id);

    const second = await disburse('2');
    assert(second.legs[0]?.trade.status === 'completed', 'first leg should complete');
    assert(second.legs[1]?.payout.status === 'submitted', 'second payout should be submitted');
    await simulatePayout(trades[1]!.id);

    const third = await disburse('3');
    assert(third.match.status === 'released', `match is ${third.match.status}`);
    assert(
      third.legs.map((leg) => leg.trade.status).join(',') === 'completed,completed',
      'both legs should complete',
    );

    const journals = await db.pool.query<{
      kind: string;
      currency_code: string;
      balance_minor: string;
    }>(
      `SELECT t.kind, t.currency_code, b.balance_minor::text
       FROM journal_transactions t
       JOIN journal_transaction_balances b ON b.transaction_id = t.id
       WHERE t.trade_id IN ($1, $2)
       ORDER BY t.created_at, t.id`,
      [trades[0]!.id, trades[1]!.id],
    );
    for (const journal of journals.rows) {
      assert(BigInt(journal.balance_minor) === 0n, `${journal.kind} does not balance`);
    }
    const imbalance = await db.pool.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM journal_transaction_balances WHERE balance_minor <> 0`,
    );
    assert(imbalance.rows[0]?.count === '0', 'the ledger has an unbalanced transaction');

    console.log(
      JSON.stringify(
        {
          ok: true,
          match: { id: matchId, status: third.match.status },
          trades: trades.map((trade) => ({
            id: trade.id,
            reference: trade.reference,
            receiveAmountMinor: trade.receiveAmountMinor,
          })),
          journals: journals.rows.map((row) => `${row.kind}:${row.currency_code}`),
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
