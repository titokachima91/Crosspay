import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { createQuote, createUser, insertTrade, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import { DisabledPricingProvider } from '../src/providers/pricing.js';
import { DisabledPaymentProvider } from '../src/providers/payments.js';
import type { AppContext } from '../src/http/context.js';
import { buildAdminWebServer } from '../src/admin-web/app.js';
import type { AdminWebConfig } from '../src/admin-web/config.js';
import {
  createAdminUser,
  generateTotpSecret,
  hashToken,
  totpFor,
  type AdminRole,
} from '../src/admin-web/auth.js';

let db: TestDatabase;
let app: FastifyInstance;
let ctx: AppContext;
let config: AdminWebConfig;
let adminEmail: string;
let adminPassword: string;
let adminSecret: string;
let adminId: string;

const PASSWORD = 'correct horse battery staple';

before(async () => {
  db = await startTestDatabase();
  ctx = {
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
    adminApiKey: 'env-admin-key',
  };
  config = {
    port: 0,
    host: '127.0.0.1',
    baseUrl: 'http://127.0.0.1:3001',
    cookieSecure: false,
    sessionTtlSeconds: 3600,
    totpIssuer: 'CrossPay Admin',
  };
  adminEmail = 'ops@crosspay.test';
  adminSecret = generateTotpSecret();
  adminId = await createAdminUser(db.pool, {
    email: adminEmail,
    name: 'Ops Admin',
    password: PASSWORD,
    roles: ['superadmin'],
    totpSecret: adminSecret,
    crypto: ctx.crypto,
  });
  await db.pool.query(
    `INSERT INTO p2p_corridors
       (send_currency, receive_currency, enabled, exposure_cap_minor,
        match_deadline_seconds, spread_bps, estimated_settle_seconds)
     VALUES ('TZS', 'KES', true, 100000000, 600, 50, 120)`,
  );
  app = await buildAdminWebServer(ctx, config);
  await app.ready();
}, { timeout: 180_000 });

after(async () => {
  await app.close();
  await db.close();
});

function form(payload: Record<string, string>): {
  payload: string;
  headers: Record<string, string>;
} {
  return {
    payload: new URLSearchParams(payload).toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
  };
}

function postForm(
  url: string,
  payload: Record<string, string>,
  headers: Record<string, string> = {},
) {
  const body = form(payload);
  return app.inject({
    method: 'POST',
    url,
    payload: body.payload,
    headers: { ...body.headers, ...headers },
  });
}

function cookieFrom(response: { headers: Record<string, unknown> }, name: string): string | null {
  const header = response.headers['set-cookie'];
  const values = Array.isArray(header) ? header : typeof header === 'string' ? [header] : [];
  for (const value of values) {
    const first = value.split(';')[0] ?? '';
    const [key, ...rest] = first.split('=');
    if (key === name) return rest.join('=');
  }
  return null;
}

async function login(email = adminEmail, password = PASSWORD, secret = adminSecret) {
  const start = await postForm('/login', { email, password });
  assert.equal(start.statusCode, 302, start.body);
  assert.equal(start.headers.location, '/login/totp');
  const challenge = cookieFrom(start, 'cp_admin_challenge');
  assert.ok(challenge);

  // Tests sign in repeatedly within one TOTP window; reset the replay guard so
  // each scripted login can use the current step.
  await db.pool.query(`UPDATE admin_users SET totp_last_step = 0 WHERE email = $1`, [email]);
  const code = totpFor(email, config.totpIssuer, secret).generate();
  const verified = await postForm('/login/totp', { code }, {
    cookie: `cp_admin_challenge=${challenge}`,
  });
  assert.equal(verified.statusCode, 302, verified.body);
  const session = cookieFrom(verified, 'cp_admin_session');
  assert.ok(session);
  const stored = await db.pool.query<{ csrf_token: string }>(
    `SELECT csrf_token FROM admin_sessions WHERE token_hash = $1`,
    [hashToken(session)],
  );
  return { session, csrf: stored.rows[0]?.csrf_token ?? '' };
}

async function createRoleUser(email: string, role: AdminRole): Promise<{ email: string; secret: string }> {
  const secret = generateTotpSecret();
  await createAdminUser(db.pool, {
    email,
    name: `${role} user`,
    password: PASSWORD,
    roles: [role],
    totpSecret: secret,
    crypto: ctx.crypto,
  });
  return { email, secret };
}

describe('admin portal identity and pages', () => {
  it('redirects anonymous users to login and serves the login page', async () => {
    const root = await app.inject({ method: 'GET', url: '/' });
    assert.equal(root.statusCode, 302);
    assert.equal(root.headers.location, '/login');

    const login = await app.inject({ method: 'GET', url: '/login' });
    assert.equal(login.statusCode, 200);
    assert.match(login.body, /CrossPay Ops/);
    assert.match(login.headers['content-security-policy'] as string, /default-src 'self'/);
    assert.equal(login.headers['x-frame-options'], 'DENY');
  });

  it('completes password + TOTP login and renders the overview', async () => {
    const { session } = await login();
    const overview = await app.inject({
      method: 'GET',
      url: '/',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(overview.statusCode, 200, overview.body);
    assert.match(overview.body, /Funded queue/);
    assert.match(overview.body, /Corridors/);
    assert.match(overview.body, /TZS → KES/);
    assert.equal(overview.headers['x-robots-tag'], 'noindex, nofollow');
  });

  it('rejects a replayed TOTP code', async () => {
    await db.pool.query(`UPDATE admin_users SET totp_last_step = 0 WHERE email = $1`, [adminEmail]);
    const firstStart = await postForm('/login', { email: adminEmail, password: PASSWORD });
    const firstChallenge = cookieFrom(firstStart, 'cp_admin_challenge');
    assert.ok(firstChallenge);
    const code = totpFor(adminEmail, config.totpIssuer, adminSecret).generate();
    const first = await postForm('/login/totp', { code }, {
      cookie: `cp_admin_challenge=${firstChallenge}`,
    });
    assert.equal(first.statusCode, 302, first.body);

    const secondStart = await postForm('/login', { email: adminEmail, password: PASSWORD });
    const secondChallenge = cookieFrom(secondStart, 'cp_admin_challenge');
    assert.ok(secondChallenge);
    const replay = await postForm('/login/totp', { code }, {
      cookie: `cp_admin_challenge=${secondChallenge}`,
    });
    assert.equal(replay.statusCode, 401, replay.body);
    assert.match(replay.body, /not valid/);
  });

  it('enforces CSRF and RBAC on corridor writes', async () => {
    const { session, csrf } = await login();
    const missing = await postForm('/corridors/TZS/KES', { enabled: 'true', exposureCapMinor: '100000000' }, {
      cookie: `cp_admin_session=${session}`,
    });
    assert.equal(missing.statusCode, 403, missing.body);

    const updated = await postForm('/corridors/TZS/KES', { enabled: 'true', exposureCapMinor: '50000000', _csrf: csrf }, {
      cookie: `cp_admin_session=${session}`,
    });
    assert.equal(updated.statusCode, 303, updated.body);
    const audit = await db.pool.query<{ action: string; admin_user_id: string }>(
      `SELECT action, admin_user_id FROM admin_audit_log WHERE action = 'corridor.update' ORDER BY created_at DESC LIMIT 1`,
    );
    assert.equal(audit.rows[0]?.admin_user_id, adminId);

    const viewer = await createRoleUser('viewer@crosspay.test', 'viewer');
    const viewerLogin = await login(viewer.email, PASSWORD, viewer.secret);
    const forbidden = await postForm('/corridors/TZS/KES', { enabled: 'false', _csrf: viewerLogin.csrf }, {
      cookie: `cp_admin_session=${viewerLogin.session}`,
    });
    assert.equal(forbidden.statusCode, 403, forbidden.body);
  });

  it('renders control-room data and trade search/detail', async () => {
    const { session } = await login();
    const data = await app.inject({
      method: 'GET',
      url: '/control-room/data',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(data.statusCode, 200, data.body);
    const body = data.json() as {
      overview: { counts: { queue: number } };
      feed: unknown[];
      audit: unknown[];
    };
    assert.equal(typeof body.overview.counts.queue, 'number');
    assert.ok(Array.isArray(body.feed));
    assert.ok(Array.isArray(body.audit));

    const user = await createUser(db.pool, {
      phone: '+255755980001',
      displayName: 'Portal Customer',
      kycStatus: 'verified',
      limitCurrency: 'TZS',
    });
    const quote = await createQuote(db.pool, user);
    await insertTrade(db.pool, {
      userId: user,
      quote,
      status: 'escrowed',
      reference: 'CP-PORTAL001',
      sendAmountMinor: 1_000_000n,
      receiveAmountMinor: 54_054n,
    });
    const search = await app.inject({
      method: 'GET',
      url: '/trades?q=CP-PORTAL001',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(search.statusCode, 200, search.body);
    assert.match(search.body, /CP-PORTAL001/);
  });

  it('creates a named admin and refuses to suspend the last superadmin', async () => {
    const { session, csrf } = await login();
    const created = await postForm('/admin-users', {
      _csrf: csrf,
      email: 'finance@crosspay.test',
      name: 'Finance User',
      password: 'another strong password',
      role: 'finance',
    }, { cookie: `cp_admin_session=${session}` });
    assert.equal(created.statusCode, 303, created.body);
    const row = await db.pool.query<{ id: string }>(
      `SELECT id FROM admin_users WHERE email = 'finance@crosspay.test'`,
    );
    assert.ok(row.rows[0]?.id);

    const selfSuspend = await postForm(`/admin-users/${adminId}/status`, { _csrf: csrf, status: 'suspended' }, {
      cookie: `cp_admin_session=${session}`,
    });
    assert.equal(selfSuspend.statusCode, 409, selfSuspend.body);
  });

  it('enrols TOTP for a new admin on first login', async () => {
    const email = 'new-ops@crosspay.test';
    const id = await createAdminUser(db.pool, {
      email,
      name: 'New Ops',
      password: PASSWORD,
      roles: ['ops'],
      crypto: ctx.crypto,
    });
    const start = await postForm('/login', { email, password: PASSWORD });
    assert.equal(start.statusCode, 302);
    assert.equal(start.headers.location, '/setup-totp');
    const challenge = cookieFrom(start, 'cp_admin_challenge');
    assert.ok(challenge);

    const setup = await app.inject({
      method: 'GET',
      url: '/setup-totp',
      headers: { cookie: `cp_admin_challenge=${challenge}` },
    });
    assert.equal(setup.statusCode, 200, setup.body);
    assert.match(setup.body, /data:image\/png;base64/);

    const secretRow = await db.pool.query<{ secret_encrypted: Buffer }>(
      `SELECT secret_encrypted FROM admin_login_challenges
       WHERE admin_user_id = $1 ORDER BY created_at DESC LIMIT 1`,
      [id],
    );
    const secret = ctx.crypto.decrypt(secretRow.rows[0]?.secret_encrypted as Buffer);
    const code = totpFor(email, config.totpIssuer, secret).generate();
    const done = await postForm('/setup-totp', { code }, {
      cookie: `cp_admin_challenge=${challenge}`,
    });
    assert.equal(done.statusCode, 200, done.body);
    assert.match(done.body, /Recovery codes/);
    assert.ok(cookieFrom(done, 'cp_admin_session'));
  });
});
