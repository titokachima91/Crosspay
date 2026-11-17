import assert from 'node:assert/strict';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { after, before, describe, it } from 'node:test';
import {
  DisabledPaymentProvider,
  PaymentRejectedError,
  PaymentUnavailableError,
  SandboxPaymentProvider,
} from '../src/providers/payments.js';

let server: ReturnType<typeof createServer>;
let baseUrl: string;
const calls: Array<{ url: string; method: string; body: Record<string, unknown>; key?: string; idem?: string }> = [];

function send(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(body));
}

function handler(request: IncomingMessage, response: ServerResponse): void {
  const chunks: Buffer[] = [];
  request.on('data', (chunk: Buffer) => chunks.push(chunk));
  request.on('end', () => {
    let body: Record<string, unknown> = {};
    try { body = JSON.parse(Buffer.concat(chunks).toString()) as Record<string, unknown>; } catch { /* empty */ }
    const url = request.url ?? '/';
    calls.push({
      url,
      method: request.method ?? 'GET',
      body,
      key: request.headers['x-api-key'] as string | undefined,
      idem: request.headers['idempotency-key'] as string | undefined,
    });

    if (url === '/api/sandbox/psp/providers') {
      return send(response, 200, {
        success: true,
        providers: [
          {
            id: 'MPESA_TZ',
            name: 'M-Pesa Tanzania',
            currency: 'TZS',
            kind: 'mobile_money',
            phonePrefixes: ['^\\+255(74|75|76|79)'],
          },
          {
            id: 'TIGOPESA',
            name: 'Tigo Pesa',
            currency: 'TZS',
            kind: 'mobile_money',
            phonePrefixes: ['^\\+255(65|67|71|77)'],
          },
          {
            id: 'MPESA_KE',
            name: 'M-Pesa Kenya',
            currency: 'KES',
            kind: 'mobile_money',
            phonePrefixes: ['^\\+254(1|7)'],
          },
        ],
      });
    }

    if (url === '/api/sandbox/psp/stk-push') {
      if (body['phoneNumber'] === '+255700000503') {
        return send(response, 503, { error: 'PROVIDER_UNAVAILABLE', message: 'Down' });
      }
      if (body['phoneNumber'] === '+255700000422') {
        return send(response, 422, { error: { code: 'WALLET_NOT_FOUND', message: 'No wallet' } });
      }
      if (body['phoneNumber'] === '+255700000500') {
        return send(response, 202, { request: { checkoutRequestId: 42 } });
      }
      return send(response, 202, {
        success: true,
        status: 'PENDING',
        checkoutRequestId: 'ws_1',
        request: {
          checkoutRequestId: 'ws_1',
          transactionRef: body['transactionRef'],
          provider: body['provider'] ?? 'MPESA_TZ',
          phoneNumber: body['phoneNumber'],
          amountMinor: body['amountMinor'],
          currency: body['currency'],
          feeMinor: 100,
          status: 'PENDING',
          walletBacked: true,
        },
      });
    }

    if (url === '/api/sandbox/psp/requests/ws_1') {
      return send(response, 200, {
        success: true,
        request: {
          checkoutRequestId: 'ws_1',
          transactionRef: 'COL-1',
          provider: 'MPESA_TZ',
          phoneNumber: '+255754123456',
          amountMinor: 100000,
          currency: 'TZS',
          feeMinor: 100,
          status: 'SUCCESS',
        },
      });
    }

    if (url === '/api/sandbox/psp/requests/missing') {
      return send(response, 404, { error: 'REQUEST_NOT_FOUND', message: 'Not found' });
    }

    if (url === '/api/sandbox/psp/payouts') {
      return send(response, 202, {
        success: true,
        payout: {
          payoutId: 'payout_1',
          transactionRef: body['transactionRef'],
          provider: 'MPESA_TZ',
          phoneNumber: body['phoneNumber'],
          amountMinor: body['amountMinor'],
          currency: body['currency'],
          feeMinor: 0,
          status: 'PENDING',
        },
      });
    }

    if (url === '/api/sandbox/psp/payouts/payout_1') {
      return send(response, 200, {
        success: true,
        payout: {
          payoutId: 'payout_1',
          transactionRef: 'PAY-1',
          provider: 'MPESA_TZ',
          phoneNumber: '+255754123456',
          amountMinor: 50000,
          currency: 'TZS',
          feeMinor: 0,
          status: 'SUCCESS',
        },
      });
    }

    if (url === '/api/sandbox/psp/refunds') {
      return send(response, 200, {
        refundId: 'refund_1',
        requestId: body['requestId'],
        amountMinor: body['amountMinor'],
        currency: 'TZS',
        status: 'PARTIALLY_REFUNDED',
        feeRefundMinor: 10,
      });
    }

    if (url === '/api/sandbox/bank/accounts/ACC_1') {
      return send(response, 200, {
        success: true,
        account: {
          accountRef: 'ACC_1',
          name: 'Test Customer',
          currency: 'TZS',
          type: 'customer',
          ownerType: 'CUSTOMER',
          purpose: 'CUSTOMER_DEPOSIT',
          status: 'ACTIVE',
          institutionId: 'CRDB_TZ',
          balanceMinor: 100000,
        },
      });
    }

    if (url === '/api/sandbox/bank/accounts/missing') {
      return send(response, 404, { error: 'ACCOUNT_NOT_FOUND', message: 'Not found' });
    }

    if (url === '/api/sandbox/bank/transfer') {
      return send(response, 200, {
        success: true,
        transfer: {
          transactionRef: body['transactionRef'],
          state: 'COMPLETED',
          amountMinor: body['amountMinor'],
          currency: 'TZS',
          fromAccount: body['fromAccount'],
          toAccount: body['toAccount'],
        },
      });
    }

    send(response, 404, { error: 'NOT_FOUND', message: 'Not found' });
  });
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

function provider(): SandboxPaymentProvider {
  // The suite runs embedded PostgreSQL clusters before this file; a 2-second
  // socket timeout is too tight under that load even though the test server is
  // local. Keep the adapter's own timeout covered by the slow-response test.
  return new SandboxPaymentProvider({ baseUrl, apiKey: 'provider-key', timeoutMs: 15_000 });
}

describe('sandbox payment provider adapter', () => {
  it('creates and reads a collection with the provider key and idempotency', async () => {
    calls.length = 0;
    const collection = await provider().createCollection({
      phoneNumber: '+255754123456',
      amountMinor: 100000,
      currency: 'TZS',
      transactionRef: 'COL-1',
      institutionId: 'MPESA_TZ',
    });
    assert.equal(collection.checkoutRequestId, 'ws_1');
    assert.equal(collection.status, 'PENDING');
    assert.equal(collection.walletBacked, true);
    assert.equal(calls[0]?.key, 'provider-key');
    assert.equal(calls[0]?.idem, 'COL-1');
    assert.equal(calls[0]?.body['transactionRef'], 'COL-1');

    const read = await provider().getCollection('ws_1');
    assert.equal(read?.status, 'SUCCESS');
    assert.equal(await provider().getCollection('missing'), null);
  });

  it('creates and reads a payout', async () => {
    const payout = await provider().createPayout({
      phoneNumber: '+255754123456',
      amountMinor: 50000,
      currency: 'TZS',
      transactionRef: 'PAY-1',
    });
    assert.equal(payout.payoutId, 'payout_1');
    assert.equal(payout.status, 'PENDING');
    const read = await provider().getPayout('payout_1');
    assert.equal(read?.status, 'SUCCESS');
  });

  it('refunds a collection', async () => {
    const refund = await provider().refund({
      requestId: 'ws_1',
      amountMinor: 10000,
      reason: 'test',
    });
    assert.equal(refund.refundId, 'refund_1');
    assert.equal(refund.status, 'PARTIALLY_REFUNDED');
  });

  it('reads a bank account and transfers', async () => {
    const account = await provider().getBankAccount('ACC_1');
    assert.equal(account?.ownerType, 'CUSTOMER');
    assert.equal(account?.balanceMinor, 100000);
    assert.equal(await provider().getBankAccount('missing'), null);

    const transfer = await provider().transfer({
      transactionRef: 'TRF-1',
      fromAccount: 'ACC_1',
      toAccount: 'ACC_2',
      amountMinor: 25000,
    });
    assert.equal(transfer.state, 'COMPLETED');
    assert.equal(transfer.amountMinor, 25000);
  });

  it('maps rejection, outage and malformed responses honestly', async () => {
    const rejected = await provider()
      .createCollection({
        phoneNumber: '+255700000422',
        amountMinor: 1000,
        currency: 'TZS',
        transactionRef: 'REJ-1',
      })
      .catch((error: unknown) => error);
    assert.ok(rejected instanceof PaymentRejectedError);
    assert.equal(rejected.code, 'WALLET_NOT_FOUND');
    assert.equal(rejected.statusCode, 422);

    const outage = await provider()
      .createCollection({
        phoneNumber: '+255700000503',
        amountMinor: 1000,
        currency: 'TZS',
        transactionRef: 'DOWN-1',
      })
      .catch((error: unknown) => error);
    assert.ok(outage instanceof PaymentUnavailableError);
    assert.equal(outage.code, 'PAYMENT_PROVIDER_UNAVAILABLE');

    const malformed = await provider()
      .createCollection({
        phoneNumber: '+255700000500',
        amountMinor: 1000,
        currency: 'TZS',
        transactionRef: 'BAD-1',
      })
      .catch((error: unknown) => error);
    assert.ok(malformed instanceof PaymentUnavailableError);
    assert.equal(malformed.code, 'PAYMENT_PROVIDER_INVALID_RESPONSE');
  });

  it('discovers the sandbox PSP from the currency and phone prefix when none is named', async () => {
    calls.length = 0;
    const collection = await provider().createCollection({
      phoneNumber: '+255754123456',
      amountMinor: 100000,
      currency: 'TZS',
      transactionRef: 'COL-DISCOVER',
    });
    assert.equal(collection.provider, 'MPESA_TZ');
    assert.equal(calls[0]?.url, '/api/sandbox/psp/providers');
    assert.equal(calls[0]?.key, 'provider-key');

    const push = calls.find((call) => call.url === '/api/sandbox/psp/stk-push');
    assert.ok(push, 'expected the adapter to call stk-push after discovery');
    assert.equal(push.body['provider'], 'MPESA_TZ');

    const kes = await provider().createCollection({
      phoneNumber: '+254712345678',
      amountMinor: 100000,
      currency: 'KES',
      transactionRef: 'COL-DISCOVER-KE',
    });
    assert.equal(kes.provider, 'MPESA_KE');
  });

  it('keeps the disabled default honest', async () => {
    const disabled = new DisabledPaymentProvider();
    await assert.rejects(
      disabled.createCollection(),
      (error: unknown) =>
        error instanceof PaymentUnavailableError &&
        error.code === 'PAYMENT_PROVIDER_NOT_CONFIGURED',
    );
  });
});
