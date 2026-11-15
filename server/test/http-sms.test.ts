import assert from 'node:assert/strict';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { after, before, describe, it } from 'node:test';
import { HttpSmsSender, SmsDeliveryError } from '../src/providers/http-sms.js';

let server: ReturnType<typeof createServer>;
let baseUrl: string;
const requests: Array<{ body: Record<string, unknown>; headers: IncomingMessage['headers'] }> = [];
let mode: 'ok' | 'http-error' | 'rejected' | 'plain' | 'slow' = 'ok';

function handler(request: IncomingMessage, response: ServerResponse): void {
  const chunks: Buffer[] = [];
  request.on('data', (chunk: Buffer) => chunks.push(chunk));
  request.on('end', () => {
    let body: Record<string, unknown> = {};
    try { body = JSON.parse(Buffer.concat(chunks).toString()) as Record<string, unknown>; } catch { /* ignore */ }
    requests.push({ body, headers: request.headers });

    if (mode === 'http-error') {
      response.writeHead(500, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: 'gateway down' }));
      return;
    }
    if (mode === 'rejected') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ success: false, error: 'sender blocked' }));
      return;
    }
    if (mode === 'plain') {
      response.writeHead(200, { 'content-type': 'text/plain' });
      response.end('accepted');
      return;
    }
    if (mode === 'slow') {
      setTimeout(() => {
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ success: true }));
      }, 120);
      return;
    }
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ success: true }));
  });
}

before(async () => {
  server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  baseUrl = `http://127.0.0.1:${address.port}/v1/send-sms`;
});

after(async () => {
  await new Promise<void>((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
});

describe('HTTP SMS adapter', () => {
  it('posts the OTP in the gateway contract without exposing it in errors', async () => {
    mode = 'ok';
    requests.length = 0;
    const sender = new HttpSmsSender({
      url: baseUrl,
      apiKey: 'gateway-key',
      senderId: 'CROSSPAY',
      timeoutMs: 2_000,
    });

    await sender.sendOtp('+255755123456', '123456');
    assert.equal(requests.length, 1);
    assert.equal(requests[0]?.headers['x-api-key'], 'gateway-key');
    assert.equal(requests[0]?.body['recipient'], '+255755123456');
    assert.match(String(requests[0]?.body['message']), /123456/);
    assert.equal(requests[0]?.body['senderId'], 'CROSSPAY');
  });

  it('maps a gateway error to SMS_DELIVERY_FAILED without leaking the code', async () => {
    mode = 'http-error';
    const sender = new HttpSmsSender({ url: baseUrl, timeoutMs: 2_000 });
    const error = await sender.sendOtp('+255755123456', '654321').catch((value: unknown) => value);
    assert.ok(error instanceof SmsDeliveryError);
    assert.equal(error.code, 'SMS_DELIVERY_FAILED');
    assert.doesNotMatch(error.message, /654321/);
  });

  it('rejects an HTTP 200 success:false response', async () => {
    mode = 'rejected';
    const sender = new HttpSmsSender({ url: baseUrl, timeoutMs: 2_000 });
    await assert.rejects(
      sender.sendOtp('+255755123456', '111111'),
      (error: unknown) => error instanceof SmsDeliveryError,
    );
  });

  it('accepts a plain 2xx response but times out an unresponsive gateway', async () => {
    mode = 'plain';
    const sender = new HttpSmsSender({ url: baseUrl, timeoutMs: 2_000 });
    await sender.sendOtp('+255755123456', '222222');

    mode = 'slow';
    const slow = new HttpSmsSender({ url: baseUrl, timeoutMs: 30 });
    await assert.rejects(
      slow.sendOtp('+255755123456', '333333'),
      (error: unknown) => error instanceof SmsDeliveryError,
    );
  });
});
