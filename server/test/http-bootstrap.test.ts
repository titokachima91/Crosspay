import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { startTestDatabase } from './helpers/test-database.js';
import { CapturingSmsSender } from './helpers/fake-sms.js';
import { CryptoBox } from '../src/crypto.js';
import { buildServer } from '../src/http/server.js';
import type { AppContext } from '../src/http/context.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { HttpSmsSender } from '../src/providers/http-sms.js';
import { DisabledPricingProvider } from '../src/providers/pricing.js';

let db: TestDatabase;
let app: FastifyInstance;
let sms: CapturingSmsSender;
let context: AppContext;

before(async () => {
  db = await startTestDatabase();
  sms = new CapturingSmsSender();
  context = {
    pool: db.pool,
    crypto: new CryptoBox(randomBytes(32)),
    smsSender: sms,
    pricingProvider: new DisabledPricingProvider(),
    jwtSecret: randomBytes(32),
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 3600,
    idempotencyTtlSeconds: 86_400,
    limitTimezone: 'UTC',
  };
  app = await buildServer(context);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

describe('HTTP bootstrap, auth and recipients', () => {
  it('serves /config and reports honest unavailable states', async () => {
    const config = await app.inject({ method: 'GET', url: '/api/v1/config' });
    assert.equal(config.statusCode, 200);
    const body = config.json() as {
      currencies: unknown[];
      hubs: unknown[];
      payoutRails: Array<{ kind: string }>;
      countries: unknown[];
      carriers: unknown[];
    };
    assert.ok(body.currencies.length > 0);
    assert.ok(body.hubs.length > 0);
    assert.ok(body.countries.length > 0);
    assert.ok(body.carriers.length > 0);
    assert.ok(body.payoutRails.every((rail) => ['mobile_money', 'bank'].includes(rail.kind)));

    const rates = await app.inject({ method: 'GET', url: '/api/v1/rates' });
    assert.equal(rates.statusCode, 503);
    assert.equal((rates.json() as { error: { code: string } }).error.code, 'PRICING_NOT_CONFIGURED');

    const unauthorized = await app.inject({ method: 'GET', url: '/api/v1/me' });
    assert.equal(unauthorized.statusCode, 401);
    assert.equal((unauthorized.json() as { error: { code: string } }).error.code, 'UNAUTHORIZED');
  });

  it('signs in, completes KYC and manages recipients idempotently', async () => {
    const phone = '+255755123456';

    const requested = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/otp/request',
      payload: { phone },
    });
    assert.equal(requested.statusCode, 200);
    const challenge = requested.json() as {
      codeLength: number;
      resendAfterSeconds: number;
      expiresInSeconds: number;
    };
    assert.equal(challenge.codeLength, 6);
    assert.ok(challenge.expiresInSeconds > 0);
    const code = sms.lastCode(phone);
    assert.ok(code);

    const wrong = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/otp/verify',
      payload: { phone, code: '000000' },
    });
    assert.equal(wrong.statusCode, 422);
    assert.equal((wrong.json() as { error: { code: string } }).error.code, 'OTP_INVALID');

    const verified = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/otp/verify',
      payload: { phone, code },
    });
    assert.equal(verified.statusCode, 200);
    const session = verified.json() as {
      accessToken: string;
      refreshToken: string;
      expiresInSeconds: number;
      profileComplete: boolean;
    };
    assert.ok(session.accessToken);
    assert.ok(session.refreshToken);
    assert.equal(session.expiresInSeconds, 900);
    assert.equal(session.profileComplete, false);

    const authorization = `Bearer ${session.accessToken}`;
    const beforeKyc = await app.inject({
      method: 'GET',
      url: '/api/v1/me',
      headers: { authorization },
    });
    assert.equal(beforeKyc.statusCode, 409);
    assert.equal((beforeKyc.json() as { error: { code: string } }).error.code, 'PROFILE_INCOMPLETE');

    const kyc = await app.inject({
      method: 'PUT',
      url: '/api/v1/me/kyc',
      headers: { authorization },
      payload: {
        accountType: 'personal',
        legalName: 'Amina Hassan',
        idNumber: '19900101-12345-6789',
      },
    });
    assert.equal(kyc.statusCode, 200);
    assert.deepEqual(kyc.json(), { kycStatus: 'pending' });

    const me = await app.inject({
      method: 'GET',
      url: '/api/v1/me',
      headers: { authorization },
    });
    assert.equal(me.statusCode, 200);
    const profile = me.json() as {
      phone: string;
      displayName: string;
      kycStatus: string;
      tier: string;
      limit: { currency: string; dailyLimitMinor: number; dailyUsedMinor: number };
    };
    assert.equal(profile.phone, phone);
    assert.equal(profile.displayName, 'Amina Hassan');
    assert.equal(profile.kycStatus, 'pending');
    assert.equal(profile.tier, 'starter');
    assert.deepEqual(profile.limit, {
      currency: 'TZS',
      dailyLimitMinor: 0,
      dailyUsedMinor: 0,
    });

    const createKey = 'http-create-recipient-1';
    const missingKey = await app.inject({
      method: 'POST',
      url: '/api/v1/beneficiaries',
      headers: { authorization },
      payload: {
        railId: 'mpesa-tz',
        name: 'Amina Hassan',
        accountOrPhone: '+255 755 123456',
      },
    });
    assert.equal(missingKey.statusCode, 400);
    assert.equal(
      (missingKey.json() as { error: { code: string } }).error.code,
      'IDEMPOTENCY_KEY_REQUIRED',
    );

    const create = await app.inject({
      method: 'POST',
      url: '/api/v1/beneficiaries',
      headers: { authorization, 'x-idempotency-key': createKey },
      payload: {
        railId: 'mpesa-tz',
        name: 'Amina Hassan',
        accountOrPhone: '+255 755 123456',
      },
    });
    assert.equal(create.statusCode, 201);
    const recipient = create.json() as {
      id: string;
      name: string;
      railId: string;
      accountOrPhone: string;
      kycVerified: boolean;
    };
    assert.equal(recipient.name, 'Amina Hassan');
    assert.equal(recipient.railId, 'mpesa-tz');
    assert.equal(recipient.accountOrPhone, '+255755123456');
    assert.equal(recipient.kycVerified, false);

    const replay = await app.inject({
      method: 'POST',
      url: '/api/v1/beneficiaries',
      headers: { authorization, 'x-idempotency-key': createKey },
      payload: {
        railId: 'mpesa-tz',
        name: 'Amina Hassan',
        accountOrPhone: '+255 755 123456',
      },
    });
    assert.equal(replay.statusCode, 201);
    assert.equal(replay.headers['idempotency-replay'], 'true');
    assert.deepEqual(replay.json(), recipient);

    const differentBody = await app.inject({
      method: 'POST',
      url: '/api/v1/beneficiaries',
      headers: { authorization, 'x-idempotency-key': createKey },
      payload: {
        railId: 'mpesa-tz',
        name: 'Another Name',
        accountOrPhone: '+255 755 123456',
      },
    });
    assert.equal(differentBody.statusCode, 409);
    assert.equal(
      (differentBody.json() as { error: { code: string } }).error.code,
      'IDEMPOTENCY_KEY_REUSED',
    );

    const list = await app.inject({
      method: 'GET',
      url: '/api/v1/beneficiaries',
      headers: { authorization },
    });
    assert.equal(list.statusCode, 200);
    assert.equal((list.json() as { beneficiaries: unknown[] }).beneficiaries.length, 1);

    const update = await app.inject({
      method: 'PATCH',
      url: `/api/v1/beneficiaries/${recipient.id}`,
      headers: { authorization, 'x-idempotency-key': 'http-update-recipient-1' },
      payload: {
        railId: 'mpesa-tz',
        name: 'Amina H.',
        accountOrPhone: '+255 755 123456',
      },
    });
    assert.equal(update.statusCode, 200);
    assert.equal((update.json() as { name: string }).name, 'Amina H.');

    const remove = await app.inject({
      method: 'DELETE',
      url: `/api/v1/beneficiaries/${recipient.id}`,
      headers: { authorization, 'x-idempotency-key': 'http-delete-recipient-1' },
    });
    assert.equal(remove.statusCode, 204);

    const removeReplay = await app.inject({
      method: 'DELETE',
      url: `/api/v1/beneficiaries/${recipient.id}`,
      headers: { authorization, 'x-idempotency-key': 'http-delete-recipient-1' },
    });
    assert.equal(removeReplay.statusCode, 204);
    assert.equal(removeReplay.headers['idempotency-replay'], 'true');

    const empty = await app.inject({
      method: 'GET',
      url: '/api/v1/beneficiaries',
      headers: { authorization },
    });
    assert.equal((empty.json() as { beneficiaries: unknown[] }).beneficiaries.length, 0);
  });

  it('rotates refresh tokens and revokes a family on reuse', async () => {
    const phone = '+255755123457';
    await app.inject({
      method: 'POST',
      url: '/api/v1/auth/otp/request',
      payload: { phone },
    });
    const code = sms.lastCode(phone);
    assert.ok(code);
    const login = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/otp/verify',
      payload: { phone, code },
    });
    assert.equal(login.statusCode, 200);
    const first = login.json() as { accessToken: string; refreshToken: string };

    const rotated = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refreshToken: first.refreshToken },
    });
    assert.equal(rotated.statusCode, 200);
    const second = rotated.json() as { accessToken: string; refreshToken: string };
    assert.ok(second.accessToken);
    assert.notEqual(second.refreshToken, first.refreshToken);

    const reuse = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refreshToken: first.refreshToken },
    });
    assert.equal(reuse.statusCode, 401);
    assert.equal(
      (reuse.json() as { error: { code: string } }).error.code,
      'REFRESH_TOKEN_REUSED',
    );

    const afterRevocation = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refreshToken: second.refreshToken },
    });
    assert.equal(afterRevocation.statusCode, 401);
    assert.equal(
      (afterRevocation.json() as { error: { code: string } }).error.code,
      'REFRESH_TOKEN_REUSED',
    );
  });

  it('rate-limits repeated verification code requests', async () => {
    const phone = '+255755999000';
    let lastStatus = 0;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/v1/auth/otp/request',
        payload: { phone },
      });
      lastStatus = response.statusCode;
    }
    assert.equal(lastStatus, 429);
  });

  it('never pretends to deliver a code when SMS is disabled', async () => {
    const disabled = await buildServer({ ...context, smsSender: new DisabledSmsSender() });
    await disabled.ready();
    try {
      const response = await disabled.inject({
        method: 'POST',
        url: '/api/v1/auth/otp/request',
        payload: { phone: '+255755999111' },
      });
      assert.equal(response.statusCode, 503);
      const body = response.json() as { error: { code: string } };
      assert.equal(body.error.code, 'SMS_NOT_CONFIGURED');
      assert.deepEqual(Object.keys(body), ['error']);
    } finally {
      await disabled.close();
    }
  });

  it('delivers an OTP through the HTTP SMS adapter and verifies it', async () => {
    const received: Array<{ recipient: string; message: string }> = [];
    const gateway = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on('data', (chunk: Buffer) => chunks.push(chunk));
      request.on('end', () => {
        received.push(JSON.parse(Buffer.concat(chunks).toString()) as { recipient: string; message: string });
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ success: true }));
      });
    });
    await new Promise<void>((resolve) => gateway.listen(0, '127.0.0.1', resolve));
    const address = gateway.address();
    assert.ok(address && typeof address !== 'string');

    const wired = await buildServer({
      ...context,
      smsSender: new HttpSmsSender({
        url: `http://127.0.0.1:${address.port}/v1/send-sms`,
        timeoutMs: 2_000,
      }),
    });
    await wired.ready();
    try {
      const phone = '+255755999777';
      const requested = await wired.inject({
        method: 'POST',
        url: '/api/v1/auth/otp/request',
        payload: { phone },
      });
      assert.equal(requested.statusCode, 200);
      const body = requested.json() as { codeLength: number; expiresInSeconds: number };
      assert.equal(body.codeLength, 6);
      assert.ok(body.expiresInSeconds > 0);
      assert.equal(received.length, 1);
      assert.equal(received[0]?.recipient, phone);
      const code = received[0]?.message.match(/\b\d{6}\b/)?.[0];
      assert.ok(code);

      const verified = await wired.inject({
        method: 'POST',
        url: '/api/v1/auth/otp/verify',
        payload: { phone, code },
      });
      assert.equal(verified.statusCode, 200);
      const session = verified.json() as { accessToken: string };
      assert.ok(session.accessToken);
    } finally {
      await wired.close();
      await new Promise<void>((resolve, reject) =>
        gateway.close((error) => (error ? reject(error) : resolve())),
      );
    }
  });
});
