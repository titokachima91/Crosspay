import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { FastifyInstance } from 'fastify';
import type { TestDatabase } from './helpers/test-database.js';
import { createQuote, createUser, insertTrade, startTestDatabase } from './helpers/test-database.js';
import { CryptoBox } from '../src/crypto.js';
import { DisabledSmsSender } from '../src/providers/sms.js';
import type { SmsSender } from '../src/providers/sms.js';
import { CapturingSmsSender } from './helpers/fake-sms.js';
import { DisabledPricingProvider } from '../src/providers/pricing.js';
import { DisabledPaymentProvider } from '../src/providers/payments.js';
import type { AppContext } from '../src/http/context.js';
import { buildAdminWebServer } from '../src/admin-web/app.js';
import type { AdminWebConfig } from '../src/admin-web/config.js';
import { ActivityStream } from '../src/admin-web/activity.js';
import { withTransaction } from '../src/db/pool.js';
import { postJournal } from '../src/ledger.js';
import { ledgerAccountId } from '../src/trades.js';
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

async function supportFixture(
  phone: string,
  reference: string,
): Promise<{ user: string; tradeId: string }> {
  const user = await createUser(db.pool, {
    phone,
    displayName: 'Support Customer',
    kycStatus: 'verified',
    limitCurrency: 'TZS',
  });
  const quote = await createQuote(db.pool, user);
  const tradeId = await insertTrade(db.pool, {
    userId: user,
    quote,
    status: 'escrowed',
    reference,
  });
  await db.pool.query(
    `UPDATE trades SET beneficiary_account_encrypted = $2 WHERE id = $1`,
    [tradeId, ctx.crypto.encrypt('0123456789')],
  );
  return { user, tradeId };
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
      events: unknown[];
      audit: unknown[];
    };
    assert.equal(typeof body.overview.counts.queue, 'number');
    assert.ok(Array.isArray(body.events));
    assert.ok(Array.isArray(body.audit));

    const user = await createUser(db.pool, {
      phone: '+255755980001',
      displayName: 'Portal Customer',
      kycStatus: 'verified',
      limitCurrency: 'TZS',
    });
    const quote = await createQuote(db.pool, user);
    const tradeId = await insertTrade(db.pool, {
      userId: user,
      quote,
      status: 'escrowed',
      reference: 'CP-PORTAL001',
      sendAmountMinor: 1_000_000n,
      receiveAmountMinor: 54_054n,
    });
    await db.pool.query(
      `INSERT INTO trade_events (trade_id, status, actor, note_code)
       VALUES ($1, 'escrowed', 'server', 'test_funded')`,
      [tradeId],
    );
    const search = await app.inject({
      method: 'GET',
      url: '/trades?q=CP-PORTAL001',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(search.statusCode, 200, search.body);
    assert.match(search.body, /CP-PORTAL001/);

    const after = await app.inject({
      method: 'GET',
      url: '/control-room/data',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(after.statusCode, 200, after.body);
    const activity = after.json() as {
      events: Array<{ source: string; tradeId: string | null; summary: string }>;
    };
    const funded = activity.events.find(
      (event) => event.source === 'trade' && event.tradeId === tradeId,
    );
    assert.ok(funded, 'triggered trade activity is visible to the control room');
    assert.match(funded.summary, /CP-PORTAL001/);

    const analytics = await app.inject({
      method: 'GET',
      url: '/analytics?window=24h',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(analytics.statusCode, 200, analytics.body);
    assert.match(analytics.body, /Fee and spread revenue/);
    assert.match(analytics.body, /Funnel by send currency/);
    assert.match(analytics.body, /Last 24 hours/);

    const control = await app.inject({
      method: 'GET',
      url: '/control-room',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(control.statusCode, 200, control.body);
    assert.match(control.body, /Live activity/);
    assert.match(control.body, /control-feed/);

    const journal = await withTransaction(db.pool, async (client) => {
      const cash = await ledgerAccountId(client, { code: '1000', currency: 'TZS' });
      const payable = await ledgerAccountId(client, { code: '2000', currency: 'TZS' });
      return postJournal(client, {
        postingKey: `test:portal:opening:${Date.now()}`,
        kind: 'opening_balance',
        currencyCode: 'TZS',
        lines: [
          { accountId: cash, amountMinor: 250_000n },
          { accountId: payable, amountMinor: -250_000n },
        ],
      });
    });
    const bookkeeping = await app.inject({
      method: 'GET',
      url: '/bookkeeping',
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(bookkeeping.statusCode, 200, bookkeeping.body);
    assert.match(bookkeeping.body, /Trial balance/);
    assert.match(bookkeeping.body, /balanced/);

    const journalPage = await app.inject({
      method: 'GET',
      url: `/bookkeeping/journals/${journal.transactionId}`,
      headers: { cookie: `cp_admin_session=${session}` },
    });
    assert.equal(journalPage.statusCode, 200, journalPage.body);
    assert.match(journalPage.body, /opening_balance/);
    assert.match(journalPage.body, /250,000/);
  });

  it('streams newly committed activity to subscribers', async () => {
    const stream = new ActivityStream(db.pool, 100, 5_000);
    const received: Array<{ source: string; summary: string }> = [];
    const unsubscribe = stream.subscribe((event) => received.push(event));
    try {
      const user = await createUser(db.pool, {
        phone: '+255755980002',
        displayName: 'Stream Customer',
        kycStatus: 'verified',
        limitCurrency: 'TZS',
      });
      const quote = await createQuote(db.pool, user);
      const tradeId = await insertTrade(db.pool, {
        userId: user,
        quote,
        status: 'escrowed',
        reference: 'CP-STREAM001',
      });
      await db.pool.query(
        `INSERT INTO trade_events (trade_id, status, actor, note_code)
         VALUES ($1, 'escrowed', 'server', 'stream_test')`,
        [tradeId],
      );
      const deadline = Date.now() + 5_000;
      const hasStreamEvent = () =>
        received.some(
          (event) => event.source === 'trade' && event.summary.includes('CP-STREAM001'),
        );
      while (!hasStreamEvent() && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      assert.ok(hasStreamEvent(), 'the stream must deliver the new event');
    } finally {
      unsubscribe();
      stream.stop();
    }
  });

  it('resumes the SSE stream after the supplied cursor', async () => {
    const { session } = await login();
    const user = await createUser(db.pool, {
      phone: '+255755980003',
      displayName: 'SSE Customer',
      kycStatus: 'verified',
      limitCurrency: 'TZS',
    });
    const quote = await createQuote(db.pool, user);
    const tradeId = await insertTrade(db.pool, {
      userId: user,
      quote,
      status: 'escrowed',
      reference: 'CP-SSERESUME',
    });
    await db.pool.query(
      `INSERT INTO trade_events (trade_id, status, actor, note_code)
       VALUES ($1, 'escrowed', 'server', 'sse_one')`,
      [tradeId],
    );
    await db.pool.query(
      `INSERT INTO trade_events (trade_id, status, actor, note_code)
       VALUES ($1, 'matching', 'server', 'sse_two')`,
      [tradeId],
    );
    const events = await db.pool.query<{ id: string }>(
      `SELECT id FROM admin_activity_events
       WHERE trade_id = $1 AND payload->>'noteCode' IN ('sse_one', 'sse_two')
       ORDER BY id`,
      [tradeId],
    );
    assert.equal(events.rows.length, 2);
    const [first, second] = events.rows.map((row) => Number(row.id));

    const address = await app.listen({ port: 0, host: '127.0.0.1' });
    const controller = new AbortController();
    try {
      const response = await fetch(`${address}/control-room/stream?after=${first}`, {
        headers: { cookie: `cp_admin_session=${session}` },
        signal: controller.signal,
      });
      assert.equal(response.status, 200);
      assert.match(response.headers.get('content-type') ?? '', /text\/event-stream/);

      const reader = response.body?.getReader();
      assert.ok(reader, 'stream must have a body');
      const decoder = new TextDecoder();
      let received = '';
      const deadline = Date.now() + 5_000;
      while (!received.includes(`id: ${second}`) && Date.now() < deadline) {
        const chunk = await Promise.race([
          reader.read(),
          new Promise<null>((resolve) => setTimeout(() => resolve(null), 500)),
        ]);
        if (chunk === null) continue;
        if (chunk.done) break;
        received += decoder.decode(chunk.value, { stream: true });
      }
      assert.match(received, new RegExp(`id: ${second}\\nevent: activity`));
      assert.ok(
        !received.includes(`id: ${first}\n`),
        'a resume cursor must not replay earlier activity',
      );
    } finally {
      controller.abort();
    }
  });

  it('opens support cases, appends notes and keeps activity private', async () => {
    const ops = await createRoleUser('ops-support@crosspay.test', 'ops');
    const opsLogin = await login(ops.email, PASSWORD, ops.secret);
    const { user, tradeId } = await supportFixture('+255755980010', 'CP-SUPPORT01');

    const created = await postForm(
      '/support',
      {
        _csrf: opsLogin.csrf,
        phone: '+255755980010',
        tradeReference: 'CP-SUPPORT01',
        subject: 'Customer says the collection is missing',
        category: 'payment_not_received',
        priority: 'normal',
        openedVia: 'phone',
        note: 'Opening note from the call.',
      },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(created.statusCode, 303, created.body);
    const location = String(created.headers.location ?? '');
    const caseId = /\/support\/cases\/([0-9a-f-]{36})/.exec(location)?.[1];
    assert.ok(caseId, `case id in redirect: ${location}`);

    const list = await app.inject({
      method: 'GET',
      url: '/support',
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.equal(list.statusCode, 200, list.body);
    assert.match(list.body, /CP-SUPPORT01/);
    assert.match(list.body, /New case/);

    const customerPage = await app.inject({
      method: 'GET',
      url: `/support/customers/${user}`,
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.equal(customerPage.statusCode, 200, customerPage.body);
    assert.match(customerPage.body, /CP-SUPPORT01/);
    assert.match(customerPage.body, /…0010/);

    const newPage = await app.inject({
      method: 'GET',
      url: `/support/new?user=${user}&trade=CP-SUPPORT01`,
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.equal(newPage.statusCode, 200, newPage.body);
    assert.match(newPage.body, /Open a case/);
    assert.match(newPage.body, /CP-SUPPORT01/);

    const detail = await app.inject({
      method: 'GET',
      url: `/support/cases/${caseId}`,
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.equal(detail.statusCode, 200, detail.body);
    assert.match(detail.body, /CP-SUPPORT01/);
    assert.match(detail.body, /…0010/);
    assert.ok(!detail.body.includes('+255755980010'), 'support list must mask the phone');
    assert.match(detail.body, /Opening note from the call/);

    const note = 'SECRET-NOTE-BODY customer called again';
    const added = await postForm(
      `/support/cases/${caseId}/messages`,
      { _csrf: opsLogin.csrf, mode: 'note', body: note },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(added.statusCode, 303, added.body);
    const afterNote = await app.inject({
      method: 'GET',
      url: `/support/cases/${caseId}`,
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.match(afterNote.body, /SECRET-NOTE-BODY/);
    await assert.rejects(
      db.pool.query(`UPDATE support_case_messages SET body = 'rewritten' WHERE case_id = $1`, [
        caseId,
      ]),
      /append-only/,
    );

    const reference = await db.pool.query<{ reference: string }>(
      `SELECT reference FROM support_cases WHERE id = $1`,
      [caseId],
    );
    const activity = await db.pool.query<{ summary: string; payload: Record<string, unknown> }>(
      `SELECT summary, payload FROM admin_activity_events
       WHERE source = 'support' AND event_type = 'message.note' AND reference = $1
       ORDER BY id DESC LIMIT 1`,
      [reference.rows[0]?.reference],
    );
    assert.ok(activity.rows[0], 'support note activity is visible to the control room');
    assert.ok(!activity.rows[0]!.summary.includes('SECRET-NOTE-BODY'));
    assert.ok(!JSON.stringify(activity.rows[0]!.payload).includes('SECRET-NOTE-BODY'));
    assert.equal(
      activity.rows[0]!.payload['bodyLength'],
      note.length,
      'activity records only the message length',
    );

    const opsRow = await db.pool.query<{ id: string }>(
      `SELECT id FROM admin_users WHERE email = $1`,
      [ops.email],
    );
    const updated = await postForm(
      `/support/cases/${caseId}/update`,
      {
        _csrf: opsLogin.csrf,
        status: 'resolved',
        priority: 'high',
        assigneeAdminId: opsRow.rows[0]!.id,
      },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(updated.statusCode, 303, updated.body);
    const stored = await db.pool.query<{
      status: string;
      priority: string;
      assignee_admin_id: string;
      resolved_at: Date | null;
    }>(
      `SELECT status, priority, assignee_admin_id, resolved_at
       FROM support_cases WHERE id = $1`,
      [caseId],
    );
    assert.equal(stored.rows[0]?.status, 'resolved');
    assert.equal(stored.rows[0]?.priority, 'high');
    assert.equal(stored.rows[0]?.assignee_admin_id, opsRow.rows[0]?.id);
    assert.ok(stored.rows[0]?.resolved_at);

    const viewer = await createRoleUser('viewer-support@crosspay.test', 'viewer');
    const viewerLogin = await login(viewer.email, PASSWORD, viewer.secret);
    const forbidden = await app.inject({
      method: 'GET',
      url: '/support',
      headers: { cookie: `cp_admin_session=${viewerLogin.session}` },
    });
    assert.equal(forbidden.statusCode, 403, forbidden.body);

    const canned = await postForm(
      '/support/canned',
      {
        _csrf: opsLogin.csrf,
        title: 'Provider delay acknowledgement',
        body: 'We are checking this transaction with the provider and will update you.',
        category: 'payout_delay',
      },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(canned.statusCode, 303, canned.body);
    const storedCanned = await db.pool.query<{ id: string; active: boolean }>(
      `SELECT id, active FROM support_canned_replies
       WHERE title = 'Provider delay acknowledgement'`,
    );
    assert.equal(storedCanned.rows[0]?.active, true);
    const cannedPage = await app.inject({
      method: 'GET',
      url: '/support/canned',
      headers: { cookie: `cp_admin_session=${opsLogin.session}` },
    });
    assert.equal(cannedPage.statusCode, 200, cannedPage.body);
    assert.match(cannedPage.body, /Provider delay acknowledgement/);
    const toggled = await postForm(
      `/support/canned/${storedCanned.rows[0]!.id}/toggle`,
      { _csrf: opsLogin.csrf },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(toggled.statusCode, 303, toggled.body);
    const afterToggle = await db.pool.query<{ active: boolean }>(
      `SELECT active FROM support_canned_replies WHERE id = $1`,
      [storedCanned.rows[0]!.id],
    );
    assert.equal(afterToggle.rows[0]?.active, false);

    const trade = await db.pool.query<{ user_id: string }>(
      `SELECT user_id FROM trades WHERE id = $1`,
      [tradeId],
    );
    assert.equal(trade.rows[0]?.user_id, user);
  });

  it('requires compliance permission, a reason and an audit for PII reveal', async () => {
    const ops = await createRoleUser('ops-pii@crosspay.test', 'ops');
    const compliance = await createRoleUser('compliance-pii@crosspay.test', 'compliance');
    const opsLogin = await login(ops.email, PASSWORD, ops.secret);
    const complianceLogin = await login(compliance.email, PASSWORD, compliance.secret);
    await supportFixture('+255755980011', 'CP-SUPPORT02');

    const created = await postForm(
      '/support',
      {
        _csrf: opsLogin.csrf,
        phone: '+255755980011',
        tradeReference: 'CP-SUPPORT02',
        subject: 'Beneficiary account needs checking',
        category: 'beneficiary',
        priority: 'high',
        openedVia: 'phone',
      },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(created.statusCode, 303, created.body);
    const caseId = /\/support\/cases\/([0-9a-f-]{36})/.exec(
      String(created.headers.location ?? ''),
    )?.[1];
    assert.ok(caseId);

    const denied = await postForm(
      `/support/cases/${caseId}/reveal`,
      { _csrf: opsLogin.csrf, reason: 'Trying to help the customer' },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(denied.statusCode, 403, denied.body);

    const revealed = await postForm(
      `/support/cases/${caseId}/reveal`,
      { _csrf: complianceLogin.csrf, reason: 'Confirming the beneficiary account for a recall' },
      { cookie: `cp_admin_session=${complianceLogin.session}` },
    );
    assert.equal(revealed.statusCode, 200, revealed.body);
    assert.match(revealed.body, /\+255755980011/);
    assert.match(revealed.body, /0123456789/);
    assert.match(revealed.body, /Confirming the beneficiary account/);

    const reveals = await db.pool.query<{ reason: string }>(
      `SELECT reason FROM support_pii_reveals WHERE case_id = $1`,
      [caseId],
    );
    assert.equal(reveals.rows.length, 1);
    assert.match(reveals.rows[0]!.reason, /Confirming the beneficiary account/);

    const audit = await db.pool.query<{ reason: string; admin_user_id: string }>(
      `SELECT reason, admin_user_id FROM admin_audit_log
       WHERE action = 'support.pii.reveal' AND resource_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [caseId],
    );
    assert.match(audit.rows[0]?.reason ?? '', /Confirming the beneficiary account/);
    assert.ok(audit.rows[0]?.admin_user_id);

    const activity = await db.pool.query<{ summary: string; payload: Record<string, unknown> }>(
      `SELECT summary, payload FROM admin_activity_events
       WHERE source = 'support' AND event_type = 'pii.reveal' AND reference = (
         SELECT reference FROM support_cases WHERE id = $1
       )
       ORDER BY id DESC LIMIT 1`,
      [caseId],
    );
    assert.ok(activity.rows[0], 'PII reveal is visible to the control room');
    const serialized = JSON.stringify(activity.rows[0]);
    assert.ok(!serialized.includes('+255755980011'));
    assert.ok(!serialized.includes('0123456789'));
  });

  it('only records an SMS reply when the gateway accepts it', async () => {
    const ops = await createRoleUser('ops-sms@crosspay.test', 'ops');
    const opsLogin = await login(ops.email, PASSWORD, ops.secret);
    await supportFixture('+255755980012', 'CP-SUPPORT03');
    const created = await postForm(
      '/support',
      {
        _csrf: opsLogin.csrf,
        phone: '+255755980012',
        tradeReference: 'CP-SUPPORT03',
        subject: 'Customer needs an update',
        category: 'payout_delay',
        priority: 'normal',
        openedVia: 'phone',
      },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(created.statusCode, 303, created.body);
    const caseId = /\/support\/cases\/([0-9a-f-]{36})/.exec(
      String(created.headers.location ?? ''),
    )?.[1];
    assert.ok(caseId);

    const blocked = await postForm(
      `/support/cases/${caseId}/messages`,
      { _csrf: opsLogin.csrf, mode: 'sms', body: 'We are checking your payout.' },
      { cookie: `cp_admin_session=${opsLogin.session}` },
    );
    assert.equal(blocked.statusCode, 503, blocked.body);
    const before = await db.pool.query<{ count: number }>(
      `SELECT count(*)::int AS count FROM support_case_messages
       WHERE case_id = $1 AND channel = 'sms'`,
      [caseId],
    );
    assert.equal(before.rows[0]?.count, 0, 'nothing is recorded when SMS is not configured');

    const original = ctx.smsSender;
    const captured = new CapturingSmsSender();
    ctx.smsSender = captured;
    try {
      const sent = await postForm(
        `/support/cases/${caseId}/messages`,
        { _csrf: opsLogin.csrf, mode: 'sms', body: 'We are checking your payout.' },
        { cookie: `cp_admin_session=${opsLogin.session}` },
      );
      assert.equal(sent.statusCode, 303, sent.body);
      assert.equal(captured.texts.length, 1);
      assert.equal(captured.texts[0]?.phone, '+255755980012');
      assert.equal(captured.texts[0]?.message, 'We are checking your payout.');
    } finally {
      ctx.smsSender = original;
    }
    const sentRow = await db.pool.query<{ delivery_status: string }>(
      `SELECT delivery_status FROM support_case_messages
       WHERE case_id = $1 AND channel = 'sms' ORDER BY created_at DESC LIMIT 1`,
      [caseId],
    );
    assert.equal(sentRow.rows[0]?.delivery_status, 'sent');
    const supportCase = await db.pool.query<{
      status: string;
      first_response_at: Date | null;
    }>(`SELECT status, first_response_at FROM support_cases WHERE id = $1`, [caseId]);
    assert.equal(supportCase.rows[0]?.status, 'pending_customer');
    assert.ok(supportCase.rows[0]?.first_response_at);

    const failing: SmsSender = {
      available: true,
      async sendOtp() {},
      async sendMessage() {
        throw new Error('gateway down');
      },
    };
    ctx.smsSender = failing;
    try {
      const failed = await postForm(
        `/support/cases/${caseId}/messages`,
        { _csrf: opsLogin.csrf, mode: 'sms', body: 'Second attempt' },
        { cookie: `cp_admin_session=${opsLogin.session}` },
      );
      assert.equal(failed.statusCode, 303, failed.body);
      assert.match(String(failed.headers.location ?? ''), /error=/);
    } finally {
      ctx.smsSender = new DisabledSmsSender();
    }
    const failedRow = await db.pool.query<{
      delivery_status: string;
      error_code: string | null;
    }>(
      `SELECT delivery_status, error_code FROM support_case_messages
       WHERE case_id = $1 AND channel = 'sms' AND body = 'Second attempt'`,
      [caseId],
    );
    assert.equal(failedRow.rows[0]?.delivery_status, 'failed');
    assert.equal(failedRow.rows[0]?.error_code, 'SMS_DELIVERY_FAILED');
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
