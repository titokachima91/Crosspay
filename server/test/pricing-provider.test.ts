import assert from 'node:assert/strict';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { after, before, describe, it } from 'node:test';
import {
  PricingRejectedError,
  PricingUnavailableError,
  SandboxPricingProvider,
} from '../src/providers/pricing.js';

let server: ReturnType<typeof createServer>;
let baseUrl: string;
const requests: Array<{ url: string; key: string | undefined }> = [];

function send(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(body));
}

function handler(request: IncomingMessage, response: ServerResponse): void {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1');
  requests.push({ url: url.pathname + url.search, key: request.headers['x-api-key'] as string | undefined });

  if (url.pathname === '/api/v1/rates') {
    send(response, 200, {
      rates: [{ from: 'TZS', to: 'KES', rate: 17.5, status: { code: 'active_clearing', level: 'healthy' } }],
      sandbox: true,
    });
    return;
  }

  if (url.pathname === '/api/v1/sandbox/pricing/estimate') {
    send(response, 200, {
      rate: 17.5,
      receiveAmountMinor: 5_714_285,
      estimatedMinSeconds: 20,
      estimatedMaxSeconds: 60,
      route: 'p2p',
      sandbox: true,
    });
    return;
  }

  if (url.pathname === '/api/v1/sandbox/pricing/quote') {
    const receive = url.searchParams.get('receiveCurrency');
    const sendCurrency = url.searchParams.get('sendCurrency');
    if (receive === 'BAD') {
      send(response, 422, { error: { code: 'CORRIDOR_UNAVAILABLE', message: 'No rate' } });
      return;
    }
    if (sendCurrency === 'ERR') {
      send(response, 503, { error: { code: 'PROVIDER_UNAVAILABLE', message: 'Down' } });
      return;
    }
    if (sendCurrency === 'JUNK') {
      send(response, 200, { rate: 'not-a-number', routes: [] });
      return;
    }
    const amount = Number(url.searchParams.get('sendAmountMinor'));
    const fee = Math.floor((amount * 150) / 10_000);
    send(response, 200, {
      sendCurrency: 'TZS',
      receiveCurrency: 'KES',
      sendAmountMinor: amount,
      rate: 17.5,
      quotedAt: '2026-11-15T06:00:00.000Z',
      expiresAt: '2026-11-15T06:05:00.000Z',
      routes: [
        {
          route: 'p2p',
          feeBps: 150,
          feeMinor: fee,
          payoutMinor: 57_142,
          totalDebitMinor: amount + fee,
          estimatedMinSeconds: 20,
          estimatedMaxSeconds: 60,
          isRecommended: true,
          isAvailable: true,
          status: { code: 'active_clearing', level: 'healthy' },
          breakdown: [{ code: 'platform_fee', amountMinor: fee }],
        },
      ],
      sandbox: true,
    });
    return;
  }

  send(response, 404, { error: { code: 'NOT_FOUND', message: 'not found' } });
}

before(async () => {
  server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
});

describe('sandbox pricing provider adapter', () => {
  const provider = () => new SandboxPricingProvider({
    baseUrl: `${baseUrl}/`,
    apiKey: 'provider-key',
    // Full-suite load can delay a localhost response; the adapter's own
    // timeout behaviour is covered separately.
    timeoutMs: 15_000,
  });

  it('reads rates, estimates and quotes from the sandbox contract', async () => {
    requests.length = 0;
    const rates = await provider().rates();
    assert.equal(rates.rates[0]?.rate, 17.5);
    assert.equal(requests[0]?.key, undefined);

    const estimate = await provider().estimate({
      sendCurrency: 'TZS',
      receiveCurrency: 'KES',
      sendAmountMinor: 1_000_000,
    });
    assert.equal(estimate.receiveAmountMinor, 5_714_285);
    assert.equal(requests[1]?.key, 'provider-key');

    const quote = await provider().quote({
      sendCurrency: 'TZS',
      receiveCurrency: 'KES',
      sendAmountMinor: 1_000_000,
      phone: '+255755900001',
    });
    assert.equal(quote.rate, 17.5);
    assert.equal(quote.routes[0]?.feeMinor, 15_000);
    assert.match(requests[2]?.url ?? '', /sendAmountMinor=1000000/);
    assert.match(requests[2]?.url ?? '', /phone=%2B255755900001/);

    const rejected = await provider()
      .quote({ sendCurrency: 'TZS', receiveCurrency: 'BAD', sendAmountMinor: 1_000 })
      .catch((error: unknown) => error);
    assert.ok(rejected instanceof PricingRejectedError);
    assert.equal(rejected.code, 'CORRIDOR_UNAVAILABLE');
    assert.equal(rejected.statusCode, 422);

    const outage = await provider()
      .quote({ sendCurrency: 'ERR', receiveCurrency: 'KES', sendAmountMinor: 1_000 })
      .catch((error: unknown) => error);
    assert.ok(outage instanceof PricingUnavailableError);
    assert.equal(outage.code, 'PRICING_UNAVAILABLE');

    const malformed = await provider()
      .quote({ sendCurrency: 'JUNK', receiveCurrency: 'KES', sendAmountMinor: 1_000 })
      .catch((error: unknown) => error);
    assert.ok(malformed instanceof PricingUnavailableError);
    assert.equal(malformed.code, 'PRICING_UNAVAILABLE');
  });
});
