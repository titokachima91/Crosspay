import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import '@fastify/view';
import '@fastify/cookie';
import type { AppContext } from '../http/context.js';
import type { AdminWebConfig } from './config.js';
import { withTransaction } from '../db/pool.js';
import { postJournal } from '../ledger.js';
import { ledgerAccountId } from '../trades.js';
import { tryMatchTrade, disburseMatch } from '../matching.js';
import { refundTrade, startDisbursement } from '../payments.js';
import {
  ADMIN_CHALLENGE_COOKIE,
  ADMIN_SESSION_COOKIE,
  consumeChallenge,
  createAdminUser,
  createChallenge,
  createSession,
  findAdminByEmail,
  generateRecoveryCodes,
  generateTotpSecret,
  hashPassword,
  hashRecoveryCode,
  hasPermission,
  loadChallenge,
  loadSession,
  recordLoginAttempt,
  requirePermission,
  revokeSession,
  rolesFor,
  safeEqual,
  setTotpSecret,
  tooManyLoginFailures,
  totpFor,
  verifyPassword,
  verifyTotpStep,
  claimTotpStep,
  type AdminRole,
  type AdminSession,
} from './auth.js';
import {
  loadAdminUsers,
  loadAnalytics,
  loadAudit,
  loadCorridors,
  loadOverview,
  loadTradeDetail,
  searchTrades,
  type AnalyticsWindow,
} from './data.js';
import {
  ActivityStream,
  loadActivityAfter,
  loadActivityMaxId,
  loadRecentActivity,
  type ActivityEvent,
} from './activity.js';
import {
  JOURNAL_KINDS,
  loadJournal,
  loadJournals,
  loadTrialBalance,
} from './bookkeeping.js';

declare module 'fastify' {
  interface FastifyRequest {
    adminSession?: AdminSession | null;
  }
}

const PUBLIC_PATHS = new Set(['/login', '/login/totp', '/setup-totp', '/health']);

function errorWith(statusCode: number, code: string, message: string): Error {
  const error = new Error(message) as Error & { statusCode: number; code: string };
  error.statusCode = statusCode;
  error.code = code;
  return error;
}

function formValue(body: unknown, key: string): string {
  if (!body || typeof body !== 'object') return '';
  const value = (body as Record<string, unknown>)[key];
  return typeof value === 'string' ? value : '';
}

function formChecked(body: unknown, key: string): boolean {
  const value = (body as Record<string, unknown> | undefined)?.[key];
  return value === 'true' || value === 'on' || value === '1';
}

function jsonBody(body: unknown): Record<string, unknown> {
  return body && typeof body === 'object' ? (body as Record<string, unknown>) : {};
}

function sameOrigin(request: FastifyRequest, config: AdminWebConfig): boolean {
  const origin = request.headers.origin;
  if (!origin) return true;
  try {
    return new URL(origin).origin === new URL(config.baseUrl).origin;
  } catch {
    return false;
  }
}

function requireCsrf(request: FastifyRequest, session: AdminSession): void {
  const token = formValue(request.body, '_csrf');
  if (!token || !safeEqual(token, session.csrfToken)) {
    throw errorWith(403, 'ADMIN_CSRF_INVALID', 'The form expired. Refresh and try again.');
  }
}

function can(session: AdminSession) {
  const roles = session.user.roles;
  return {
    view: hasPermission(roles, 'view'),
    ops: hasPermission(roles, 'ops:match'),
    corridor: hasPermission(roles, 'corridor:write'),
    liquidity: hasPermission(roles, 'liquidity:write'),
    refund: hasPermission(roles, 'refund:write'),
    audit: hasPermission(roles, 'audit:read'),
    users: hasPermission(roles, 'admin:users'),
    ledger: hasPermission(roles, 'ledger:read'),
  };
}

function view(
  reply: FastifyReply,
  template: string,
  session: AdminSession | null,
  data: Record<string, unknown> = {},
) {
  return reply.view(template, {
    user: session ? session.user : null,
    csrf: session ? session.csrfToken : '',
    can: session ? can(session) : { view: false, ops: false, corridor: false, liquidity: false, refund: false, audit: false, users: false, ledger: false },
    notice: null,
    error: null,
    ...data,
  });
}

function redirect(reply: FastifyReply, path: string, message?: string): FastifyReply {
  const url = message ? `${path}${path.includes('?') ? '&' : '?'}ok=${encodeURIComponent(message)}` : path;
  return reply.code(303).redirect(url);
}

function setSessionCookie(reply: FastifyReply, token: string, config: AdminWebConfig): void {
  reply.setCookie(ADMIN_SESSION_COOKIE, token, {
    path: '/',
    httpOnly: true,
    sameSite: 'strict',
    secure: config.cookieSecure,
    maxAge: config.sessionTtlSeconds,
  });
}

function setChallengeCookie(reply: FastifyReply, token: string, config: AdminWebConfig): void {
  reply.setCookie(ADMIN_CHALLENGE_COOKIE, token, {
    path: '/',
    httpOnly: true,
    sameSite: 'strict',
    secure: config.cookieSecure,
    maxAge: 600,
  });
}

function clearCookie(reply: FastifyReply, name: string): void {
  reply.clearCookie(name, { path: '/' });
}

async function audit(
  ctx: AppContext,
  request: FastifyRequest,
  session: AdminSession | null,
  input: {
    action: string;
    resourceType: string;
    resourceId?: string | null;
    reason?: string | null;
    before?: unknown;
    after?: unknown;
  },
): Promise<void> {
  await ctx.pool.query(
    `INSERT INTO admin_audit_log
       (actor_label, admin_user_id, action, resource_type, resource_id, reason, before, after, ip)
     VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9)`,
    [
      session ? session.user.email : 'anonymous',
      session ? session.user.id : null,
      input.action,
      input.resourceType,
      input.resourceId ?? null,
      input.reason ?? null,
      input.before === undefined ? null : JSON.stringify(input.before),
      input.after === undefined ? null : JSON.stringify(input.after),
      request.ip ?? null,
    ],
  );
}

async function loadCorridorById(
  ctx: AppContext,
  send: string,
  receive: string,
) {
  return (await loadCorridors(ctx.pool)).find((row) => row.from === send && row.to === receive) ?? null;
}

function normalizeReason(value: string): string {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 63);
  return /^[a-z][a-z0-9_]{1,62}$/.test(normalized) ? normalized : 'support_request';
}

function analyticsWindow(query: unknown): AnalyticsWindow {
  const value =
    typeof query === 'object' && query && 'window' in query
      ? String((query as { window?: string }).window)
      : '';
  return value === '24h' || value === '30d' || value === 'all' ? value : '7d';
}

export function registerAdminWebRoutes(
  app: FastifyInstance,
  ctx: AppContext,
  config: AdminWebConfig,
  activity: ActivityStream,
): void {
  app.decorateRequest('adminSession', null);

  app.addHook('onRequest', async (request, reply) => {
    const path = (request.url.split('?')[0] || '/').replace(/\/+$/, '') || '/';
    if (path.startsWith('/assets/')) return;
    if (path === '/health') return;

    const token = request.cookies[ADMIN_SESSION_COOKIE];
    const session = token ? await loadSession(ctx.pool, token) : null;
    request.adminSession = session;

    if (PUBLIC_PATHS.has(path)) {
      if (session && path !== '/setup-totp') {
        return reply.redirect('/');
      }
      return;
    }

    if (!session) {
      return reply.redirect('/login');
    }
  });

  app.addHook('preValidation', async (request) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method)) return;
    const path = (request.url.split('?')[0] || '/').replace(/\/+$/, '') || '/';
    if (['/login', '/login/totp', '/setup-totp'].includes(path)) {
      if (!sameOrigin(request, config)) {
        throw errorWith(403, 'ADMIN_ORIGIN_INVALID', 'The request origin is not allowed');
      }
      return;
    }
    const session = request.adminSession;
    if (!session) throw errorWith(401, 'ADMIN_UNAUTHORIZED', 'Sign in again');
    if (!sameOrigin(request, config)) {
      throw errorWith(403, 'ADMIN_ORIGIN_INVALID', 'The request origin is not allowed');
    }
    requireCsrf(request, session);
  });

  app.setErrorHandler(async (error, request, reply) => {
    const failure = error instanceof Error ? error : new Error(String(error));
    const statusCode = typeof (error as { statusCode?: unknown }).statusCode === 'number'
      ? (error as { statusCode: number }).statusCode
      : 500;
    const code = (error as { code?: string }).code ?? 'ADMIN_ERROR';
    if (statusCode >= 500) request.log.error({ err: failure }, 'admin web error');
    const session = request.adminSession ?? null;
    return reply.code(statusCode).view(
      'error',
      {
        user: session ? session.user : null,
        csrf: session ? session.csrfToken : '',
        can: session ? can(session) : { view: false, ops: false, corridor: false, liquidity: false, refund: false, audit: false, users: false, ledger: false },
        active: '',
        notice: null,
        error: statusCode >= 500 ? 'Unexpected error. Check the service logs.' : failure.message,
        heading: code === 'ADMIN_FORBIDDEN' ? 'Not allowed' : 'Request failed',
        message: failure.message,
      },
    );
  });

  app.get('/health', async () => {
    await ctx.pool.query('SELECT 1');
    return { status: 'ok', database: 'ok' };
  });

  app.get('/login', async (request, reply) => {
    return view(reply, 'login', null, {
      email: '',
      error: typeof request.query === 'object' && request.query && 'error' in request.query ? 'Sign-in failed' : null,
    });
  });

  app.post('/login', async (request, reply) => {
    const email = formValue(request.body, 'email').trim().toLowerCase();
    const password = formValue(request.body, 'password');
    if (await tooManyLoginFailures(ctx.pool, { email, ip: request.ip })) {
      return reply.code(429).view('login', {
        user: null,
        csrf: '',
        can: {},
        active: '',
        notice: null,
        error: 'Too many attempts. Wait a few minutes and try again.',
        email,
      });
    }
    const admin = await findAdminByEmail(ctx.pool, email);
    const valid = admin && admin.status === 'active' && (await verifyPassword(admin.password_hash, password));
    await recordLoginAttempt(ctx.pool, { email, ip: request.ip, succeeded: Boolean(valid) });
    if (!admin || !valid) {
      return reply.code(401).view('login', {
        user: null,
        csrf: '',
        can: {},
        active: '',
        notice: null,
        error: 'Email or password is incorrect.',
        email,
      });
    }

    if (!admin.totp_secret_encrypted) {
      const secret = generateTotpSecret();
      const token = await createChallenge(ctx.pool, {
        adminUserId: admin.id,
        purpose: 'totp_setup',
        secretEncrypted: ctx.crypto.encrypt(secret),
      });
      setChallengeCookie(reply, token, config);
      return reply.redirect('/setup-totp');
    }

    const token = await createChallenge(ctx.pool, { adminUserId: admin.id, purpose: 'login' });
    setChallengeCookie(reply, token, config);
    return reply.redirect('/login/totp');
  });

  app.get('/login/totp', async (request, reply) => {
    const challenge = await loadChallenge(ctx.pool, {
      token: request.cookies[ADMIN_CHALLENGE_COOKIE] ?? '',
      purpose: 'login',
    });
    if (!challenge) {
      clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
      return reply.redirect('/login');
    }
    return view(reply, 'login-totp', null, { error: null });
  });

  app.post('/login/totp', async (request, reply) => {
    const challengeToken = request.cookies[ADMIN_CHALLENGE_COOKIE] ?? '';
    const challenge = await loadChallenge(ctx.pool, { token: challengeToken, purpose: 'login' });
    if (!challenge) {
      clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
      return reply.redirect('/login');
    }
    const adminResult = await ctx.pool.query<{
      email: string;
      name: string;
      totp_secret_encrypted: Buffer | null;
      status: string;
    }>(
      `SELECT email, name, totp_secret_encrypted, status FROM admin_users WHERE id = $1`,
      [challenge.adminUserId],
    );
    const admin = adminResult.rows[0];
    if (!admin || admin.status !== 'active' || !admin.totp_secret_encrypted) {
      clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
      return reply.redirect('/login');
    }
    const secret = ctx.crypto.decrypt(admin.totp_secret_encrypted);
    const step = verifyTotpStep(admin.email, config.totpIssuer, secret, formValue(request.body, 'code'));
    if (step === null || !(await claimTotpStep(ctx.pool, challenge.adminUserId, step))) {
      return reply.code(401).view('login-totp', {
        user: null,
        csrf: '',
        can: {},
        active: '',
        notice: null,
        error: 'That code is not valid. Try the next one.',
      });
    }
    await consumeChallenge(ctx.pool, { token: challengeToken, purpose: 'login' });
    const session = await createSession(ctx.pool, {
      adminUserId: challenge.adminUserId,
      ip: request.ip,
      userAgent: request.headers['user-agent'] ?? null,
      ttlSeconds: config.sessionTtlSeconds,
    });
    setSessionCookie(reply, session.token, config);
    clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
    return reply.redirect('/');
  });

  app.get('/setup-totp', async (request, reply) => {
    const challengeToken = request.cookies[ADMIN_CHALLENGE_COOKIE] ?? '';
    const challenge = await loadChallenge(ctx.pool, { token: challengeToken, purpose: 'totp_setup' });
    if (!challenge || !challenge.secretEncrypted) {
      clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
      return reply.redirect('/login');
    }
    const admin = await ctx.pool.query<{ email: string }>(
      `SELECT email FROM admin_users WHERE id = $1`,
      [challenge.adminUserId],
    );
    const email = admin.rows[0]?.email ?? '';
    const secret = ctx.crypto.decrypt(challenge.secretEncrypted);
    const { default: QRCode } = await import('qrcode');
    const qrDataUrl = await QRCode.toDataURL(totpFor(email, config.totpIssuer, secret).toString(), {
      width: 220,
      margin: 1,
      color: { dark: '#0b1117', light: '#ffffff' },
    });
    return view(reply, 'setup-totp', null, { secret, qrDataUrl, error: null });
  });

  app.post('/setup-totp', async (request, reply) => {
    const challengeToken = request.cookies[ADMIN_CHALLENGE_COOKIE] ?? '';
    const challenge = await loadChallenge(ctx.pool, { token: challengeToken, purpose: 'totp_setup' });
    if (!challenge || !challenge.secretEncrypted) {
      clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
      return reply.redirect('/login');
    }
    const admin = await ctx.pool.query<{ email: string }>(
      `SELECT email FROM admin_users WHERE id = $1`,
      [challenge.adminUserId],
    );
    const email = admin.rows[0]?.email ?? '';
    const secret = ctx.crypto.decrypt(challenge.secretEncrypted);
    const step = verifyTotpStep(email, config.totpIssuer, secret, formValue(request.body, 'code'));
    if (step === null) {
      const { default: QRCode } = await import('qrcode');
      const qrDataUrl = await QRCode.toDataURL(totpFor(email, config.totpIssuer, secret).toString(), {
        width: 220,
        margin: 1,
      });
      return reply.code(401).view('setup-totp', {
        user: null,
        csrf: '',
        can: {},
        active: '',
        notice: null,
        error: 'That code is not valid. Scan the QR code again and retry.',
        secret,
        qrDataUrl,
      });
    }
    await consumeChallenge(ctx.pool, { token: challengeToken, purpose: 'totp_setup' });
    await setTotpSecret(ctx.pool, challenge.adminUserId, ctx.crypto.encrypt(secret));
    const codes = generateRecoveryCodes(10);
    for (const code of codes) {
      await ctx.pool.query(
        `INSERT INTO admin_recovery_codes (admin_user_id, code_hash)
         VALUES ($1, $2) ON CONFLICT DO NOTHING`,
        [challenge.adminUserId, hashRecoveryCode(code)],
      );
    }
    const session = await createSession(ctx.pool, {
      adminUserId: challenge.adminUserId,
      ip: request.ip,
      userAgent: request.headers['user-agent'] ?? null,
      ttlSeconds: config.sessionTtlSeconds,
    });
    setSessionCookie(reply, session.token, config);
    clearCookie(reply, ADMIN_CHALLENGE_COOKIE);
    const loaded = await loadSession(ctx.pool, session.token);
    return reply.view('recovery-codes', {
      user: loaded?.user ?? null,
      csrf: loaded?.csrfToken ?? '',
      can: loaded ? can(loaded) : {},
      active: '',
      notice: null,
      error: null,
      codes,
    });
  });

  app.post('/logout', async (request, reply) => {
    const session = request.adminSession;
    if (session) await revokeSession(ctx.pool, session.sessionId);
    clearCookie(reply, ADMIN_SESSION_COOKIE);
    return reply.redirect('/login');
  });

  app.get('/', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const data = await loadOverview(ctx.pool);
    const notice = typeof request.query === 'object' && request.query && 'ok' in request.query
      ? String((request.query as { ok?: string }).ok)
      : null;
    return view(reply, 'overview', session, { title: 'Overview', active: 'overview', data, notice });
  });

  app.get('/control-room', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    return view(reply, 'control-room', session, { title: 'Control room', active: 'control' });
  });

  app.get('/control-room/data', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const [overview, events, auditRows] = await Promise.all([
      loadOverview(ctx.pool),
      loadRecentActivity(ctx.pool, 60),
      loadAudit(ctx.pool),
    ]);
    const updatedAt = new Date().toISOString();
    return reply.send({ overview, events, audit: auditRows.slice(0, 20), updatedAt });
  });

  app.get('/control-room/stream', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');

    const headerId = Number(request.headers['last-event-id'] ?? 0);
    const queryId = Number(
      typeof request.query === 'object' && request.query && 'after' in request.query
        ? (request.query as { after?: string }).after
        : 0,
    );
    const requested = Number.isFinite(headerId) && headerId > 0 ? headerId : queryId;
    const hasCursor = Number.isFinite(requested) && requested > 0;
    // Without a resume cursor a fresh EventSource must not replay the whole
    // outbox. Start at the current end; the page already has a snapshot.
    let lastSent = hasCursor
      ? Math.floor(requested)
      : await loadActivityMaxId(ctx.pool);

    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
      'x-content-type-options': 'nosniff',
      'x-robots-tag': 'noindex, nofollow',
    });
    raw.write('retry: 3000\n\n');

    let closed = false;
    const pending: ActivityEvent[] = [];
    let live = false;

    const write = (event: ActivityEvent): void => {
      if (closed) return;
      try {
        raw.write(
          `id: ${event.id}\nevent: activity\ndata: ${JSON.stringify(event)}\n\n`,
        );
      } catch {
        cleanup();
      }
    };

    const unsubscribe = activity.subscribe((event) => {
      if (!live) {
        pending.push(event);
        return;
      }
      // A late commit can have a lower id. Send it; the browser deduplicates by
      // id, and a lower Last-Event-ID only causes safe re-delivery.
      write(event);
      lastSent = Math.max(lastSent, event.id);
    });

    let heartbeat: NodeJS.Timeout | null = setInterval(() => {
      if (!closed) raw.write(': ping\n\n');
    }, 15_000);
    heartbeat.unref?.();

    let lifetime: NodeJS.Timeout | null = setTimeout(() => {
      if (closed) return;
      raw.write('event: close\ndata: reconnect\n\n');
      cleanup();
    }, 10 * 60_000);
    lifetime.unref?.();

    const cleanup = (): void => {
      if (closed) return;
      closed = true;
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = null;
      if (lifetime) clearTimeout(lifetime);
      lifetime = null;
      unsubscribe();
      try {
        raw.end();
      } catch {
        // The socket may already be gone.
      }
    };
    raw.on('close', cleanup);
    request.raw.on('close', cleanup);

    try {
      let cursor = lastSent;
      for (let batch = 0; batch < 10 && !closed; batch += 1) {
        const events = await loadActivityAfter(ctx.pool, cursor, 500);
        if (events.length === 0) break;
        for (const event of events) {
          if (closed) return;
          if (event.id <= lastSent) continue;
          write(event);
          lastSent = event.id;
        }
        cursor = events[events.length - 1]?.id ?? cursor;
        if (events.length < 500) break;
      }
      for (const event of pending.sort((left, right) => left.id - right.id)) {
        if (closed) return;
        if (event.id <= lastSent) continue;
        write(event);
        lastSent = event.id;
      }
      pending.length = 0;
      live = true;
    } catch (error) {
      request.log.error({ err: error }, 'control room stream failed');
      if (!closed) {
        raw.write(
          `event: error\ndata: ${JSON.stringify({ message: 'Live stream unavailable; retrying' })}\n\n`,
        );
      }
      cleanup();
    }
  });

  app.get('/analytics', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const window = analyticsWindow(request.query);
    const data = await loadAnalytics(ctx.pool, window);
    return view(reply, 'analytics', session, { title: 'Analytics', active: 'analytics', data });
  });

  app.get('/bookkeeping', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ledger:read');
    const query = (request.query ?? {}) as Record<string, string | undefined>;
    const currency = (query['currency'] ?? '').toUpperCase().slice(0, 3);
    const kind = JOURNAL_KINDS.includes((query['kind'] ?? '') as (typeof JOURNAL_KINDS)[number])
      ? String(query['kind'])
      : '';
    const reference = (query['reference'] ?? '').slice(0, 40);
    const [trialBalance, journals] = await Promise.all([
      loadTrialBalance(ctx.pool),
      loadJournals(ctx.pool, { currency, kind, reference }),
    ]);
    return view(reply, 'bookkeeping', session, {
      title: 'Bookkeeping',
      active: 'bookkeeping',
      trialBalance,
      journals,
      kinds: JOURNAL_KINDS,
      filters: { currency, kind, reference },
    });
  });

  app.get('/bookkeeping/journals/:id', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ledger:read');
    const id = (request.params as { id: string }).id;
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw errorWith(404, 'JOURNAL_NOT_FOUND', 'Journal not found');
    const journal = await loadJournal(ctx.pool, id);
    if (!journal) throw errorWith(404, 'JOURNAL_NOT_FOUND', 'Journal not found');
    return view(reply, 'journal-detail', session, {
      title: 'Journal',
      active: 'bookkeeping',
      journal,
    });
  });

  app.get('/corridors', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const data = await loadCorridors(ctx.pool);
    const notice = typeof request.query === 'object' && request.query && 'ok' in request.query
      ? String((request.query as { ok?: string }).ok)
      : null;
    return view(reply, 'corridors', session, { title: 'Corridors', active: 'corridors', data, notice });
  });

  app.post('/corridors/:send/:receive', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'corridor:write');
    const params = request.params as { send: string; receive: string };
    const send = params.send.toUpperCase();
    const receive = params.receive.toUpperCase();
    const before = await loadCorridorById(ctx, send, receive);
    if (!before) throw errorWith(404, 'CORRIDOR_NOT_FOUND', 'Corridor not found');
    const enabled = formChecked(request.body, 'enabled');
    const capRaw = formValue(request.body, 'exposureCapMinor').trim();
    const cap = capRaw === '' ? null : Number(capRaw);
    if (enabled && (cap === null || !Number.isInteger(cap) || cap <= 0)) {
      throw errorWith(422, 'CORRIDOR_CAP_REQUIRED', 'An enabled corridor needs a positive exposure cap');
    }
    const minRaw = formValue(request.body, 'minAmountMinor').trim();
    const maxRaw = formValue(request.body, 'maxAmountMinor').trim();
    const min = minRaw === '' ? null : Number(minRaw);
    const max = maxRaw === '' ? null : Number(maxRaw);
    if (min !== null && (!Number.isInteger(min) || min < 0)) {
      throw errorWith(422, 'CORRIDOR_AMOUNT_INVALID', 'Minimum amount is invalid');
    }
    if (max !== null && (!Number.isInteger(max) || max <= 0)) {
      throw errorWith(422, 'CORRIDOR_AMOUNT_INVALID', 'Maximum amount is invalid');
    }
    if (min !== null && max !== null && min >= max) {
      throw errorWith(422, 'CORRIDOR_AMOUNT_INVALID', 'Minimum must be below maximum');
    }
    const estimateRaw = formValue(request.body, 'estimatedSettleSeconds').trim();
    const estimate = estimateRaw === '' ? null : Number(estimateRaw);
    if (estimate !== null && (!Number.isInteger(estimate) || estimate <= 0)) {
      throw errorWith(422, 'CORRIDOR_ESTIMATE_INVALID', 'Estimate must be a positive integer');
    }
    const deadline = Number(formValue(request.body, 'matchDeadlineSeconds')) || before.matchDeadlineSeconds;
    const spread = formValue(request.body, 'spreadBps').trim() === ''
      ? before.spreadBps
      : Number(formValue(request.body, 'spreadBps'));
    if (!Number.isInteger(deadline) || deadline < 30 || deadline > 86_400) {
      throw errorWith(422, 'CORRIDOR_DEADLINE_INVALID', 'Deadline must be 30–86400 seconds');
    }
    if (!Number.isInteger(spread) || spread < 0 || spread > 10_000) {
      throw errorWith(422, 'CORRIDOR_SPREAD_INVALID', 'Spread must be 0–10000 bps');
    }
    await ctx.pool.query(
      `UPDATE p2p_corridors
       SET enabled = $3, exposure_cap_minor = $4,
           estimated_settle_seconds = $5, match_deadline_seconds = $6,
           spread_bps = $7, min_amount_minor = $8, max_amount_minor = $9
       WHERE send_currency = $1 AND receive_currency = $2`,
      [send, receive, enabled, cap, estimate, deadline, spread, min, max],
    );
    const after = await loadCorridorById(ctx, send, receive);
    await audit(ctx, request, session, {
      action: 'corridor.update',
      resourceType: 'p2p_corridor',
      resourceId: `${send}-${receive}`,
      before,
      after,
    });
    return redirect(reply, '/corridors', 'Corridor updated');
  });

  app.get('/liquidity', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const [providers, overview] = await Promise.all([
      ctx.pool.query(`SELECT id, name, status FROM liquidity_providers ORDER BY created_at`),
      loadOverview(ctx.pool),
    ]);
    const notice = typeof request.query === 'object' && request.query && 'ok' in request.query
      ? String((request.query as { ok?: string }).ok)
      : null;
    return view(reply, 'liquidity', session, {
      title: 'Liquidity',
      active: 'liquidity',
      providers: providers.rows,
      orders: overview.liquidityOrders,
      notice,
    });
  });

  app.post('/liquidity/providers', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'liquidity:write');
    const name = formValue(request.body, 'name').trim();
    if (name.length === 0 || name.length > 120) {
      throw errorWith(422, 'LIQUIDITY_PROVIDER_INVALID', 'A provider name is required');
    }
    const exists = await ctx.pool.query(
      `SELECT 1 FROM liquidity_providers WHERE name = $1`,
      [name],
    );
    if (exists.rowCount) {
      throw errorWith(409, 'LIQUIDITY_PROVIDER_EXISTS', 'A provider with that name exists');
    }
    const result = await ctx.pool.query(
      `INSERT INTO liquidity_providers (name) VALUES ($1)
       RETURNING id, name, status`,
      [name],
    );
    await audit(ctx, request, session, {
      action: 'liquidity_provider.create',
      resourceType: 'liquidity_provider',
      resourceId: String(result.rows[0]?.['id']),
      after: result.rows[0],
    });
    return redirect(reply, '/liquidity', 'Provider created');
  });

  app.post('/liquidity/providers/:id/status', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'liquidity:write');
    const id = (request.params as { id: string }).id;
    const status = formValue(request.body, 'status');
    if (!['active', 'suspended'].includes(status)) {
      throw errorWith(422, 'LIQUIDITY_PROVIDER_INVALID', 'Invalid provider status');
    }
    const before = await ctx.pool.query(`SELECT status FROM liquidity_providers WHERE id = $1`, [id]);
    if (!before.rows[0]) throw errorWith(404, 'LIQUIDITY_PROVIDER_NOT_FOUND', 'Provider not found');
    await ctx.pool.query(`UPDATE liquidity_providers SET status = $2 WHERE id = $1`, [id, status]);
    await audit(ctx, request, session, {
      action: 'liquidity_provider.update',
      resourceType: 'liquidity_provider',
      resourceId: id,
      before: before.rows[0],
      after: { status },
    });
    return redirect(reply, '/liquidity', 'Provider updated');
  });

  app.post('/liquidity/orders', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'liquidity:write');
    const providerId = formValue(request.body, 'providerId');
    const provideCurrency = formValue(request.body, 'provideCurrency').trim().toUpperCase();
    const receiveCurrency = formValue(request.body, 'receiveCurrency').trim().toUpperCase();
    const capacity = Number(formValue(request.body, 'capacityMinor'));
    const min = Number(formValue(request.body, 'minAmountMinor') || '0');
    const max = Number(formValue(request.body, 'maxAmountMinor'));
    const rate = Number(formValue(request.body, 'rate'));
    const expiresAt = new Date(formValue(request.body, 'expiresAt'));
    const prefundReference = formValue(request.body, 'prefundReference').trim();
    if (provideCurrency === receiveCurrency || provideCurrency.length !== 3 || receiveCurrency.length !== 3) {
      throw errorWith(422, 'LIQUIDITY_ORDER_INVALID', 'Choose two different three-letter currencies');
    }
    if (!Number.isInteger(capacity) || capacity <= 0 || !Number.isInteger(max) || max <= 0 || max > capacity || min < 0 || min >= max) {
      throw errorWith(422, 'LIQUIDITY_ORDER_INVALID', 'The order amount bounds are invalid');
    }
    if (!Number.isFinite(rate) || rate <= 0) {
      throw errorWith(422, 'LIQUIDITY_ORDER_INVALID', 'The rate must be positive');
    }
    if (Number.isNaN(expiresAt.getTime()) || expiresAt.getTime() <= Date.now()) {
      throw errorWith(422, 'LIQUIDITY_ORDER_INVALID', 'The expiry must be in the future');
    }
    if (prefundReference.length === 0) {
      throw errorWith(422, 'LIQUIDITY_ORDER_INVALID', 'A prefund reference is required');
    }
    const order = await withTransaction(ctx.pool, async (client) => {
      const provider = await client.query(
        `SELECT id FROM liquidity_providers WHERE id = $1 AND status = 'active'`,
        [providerId],
      );
      if (!provider.rowCount) {
        throw errorWith(404, 'LIQUIDITY_PROVIDER_NOT_FOUND', 'An active provider was not found');
      }
      const result = await client.query(
        `INSERT INTO liquidity_orders
           (provider_id, provide_currency, receive_currency, capacity_minor,
            remaining_minor, min_amount_minor, max_amount_minor, rate,
            prefund_reference, prefunded_at, expires_at)
         VALUES ($1, $2, $3, $4, $4, $5, $6, $7::numeric, $8, now(), $9)
         RETURNING id, provider_id, provide_currency, receive_currency,
                   capacity_minor, remaining_minor, min_amount_minor,
                   max_amount_minor, rate, status, expires_at`,
        [providerId, provideCurrency, receiveCurrency, capacity, min, max, rate, prefundReference, expiresAt],
      );
      const row = result.rows[0];
      const cash = await ledgerAccountId(client, { code: '1000', currency: provideCurrency });
      const lpPayable = await ledgerAccountId(client, { code: '2050', currency: provideCurrency });
      await postJournal(client, {
        postingKey: `lp:${row?.['id']}:prefund`,
        kind: 'opening_balance',
        currencyCode: provideCurrency,
        liquidityProviderId: providerId,
        lines: [
          { accountId: cash, amountMinor: BigInt(capacity) },
          { accountId: lpPayable, amountMinor: -BigInt(capacity) },
        ],
      });
      return row;
    });
    await audit(ctx, request, session, {
      action: 'liquidity_order.create',
      resourceType: 'liquidity_order',
      resourceId: String(order?.['id']),
      reason: prefundReference,
      after: order,
    });
    return redirect(reply, '/liquidity', 'Prefunded order created');
  });

  app.post('/liquidity/orders/:id/cancel', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'liquidity:write');
    const id = (request.params as { id: string }).id;
    const order = await withTransaction(ctx.pool, async (client) => {
      const existing = await client.query<{
        id: string;
        provider_id: string;
        provide_currency: string;
        remaining_minor: string;
        status: string;
      }>(
        `SELECT id, provider_id, provide_currency, remaining_minor, status
         FROM liquidity_orders WHERE id = $1 FOR UPDATE`,
        [id],
      );
      const row = existing.rows[0];
      if (!row || !['active', 'depleted', 'expired'].includes(row.status)) {
        throw errorWith(404, 'LIQUIDITY_ORDER_NOT_FOUND', 'An active order was not found');
      }
      const inUse = await client.query(
        `SELECT 1 FROM p2p_matches WHERE liquidity_order_id = $1 AND status = 'locked' LIMIT 1`,
        [id],
      );
      if (inUse.rowCount) {
        throw errorWith(409, 'LIQUIDITY_ORDER_IN_USE', 'A locked match still uses this order');
      }
      const remaining = BigInt(row.remaining_minor);
      if (remaining > 0n) {
        const cash = await ledgerAccountId(client, { code: '1000', currency: row.provide_currency });
        const lpPayable = await ledgerAccountId(client, { code: '2050', currency: row.provide_currency });
        await postJournal(client, {
          postingKey: `lp:${id}:return`,
          kind: 'adjustment',
          currencyCode: row.provide_currency,
          liquidityProviderId: row.provider_id,
          lines: [
            { accountId: lpPayable, amountMinor: remaining },
            { accountId: cash, amountMinor: -remaining },
          ],
        });
      }
      await client.query(`UPDATE liquidity_orders SET status = 'cancelled' WHERE id = $1`, [id]);
      return row;
    });
    await audit(ctx, request, session, {
      action: 'liquidity_order.cancel',
      resourceType: 'liquidity_order',
      resourceId: id,
      before: order,
      after: { status: 'cancelled' },
    });
    return redirect(reply, '/liquidity', 'Order cancelled and remaining prefund returned');
  });

  app.get('/trades', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const q = typeof request.query === 'object' && request.query && 'q' in request.query
      ? String((request.query as { q?: string }).q)
      : '';
    const trades = await searchTrades(ctx.pool, q);
    return view(reply, 'trades', session, { title: 'Trades', active: 'trades', trades, query: q });
  });

  app.get('/trades/:id', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'view');
    const id = (request.params as { id: string }).id;
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw errorWith(404, 'TRADE_NOT_FOUND', 'Trade not found');
    const detail = await loadTradeDetail(ctx.pool, id);
    if (!detail) throw errorWith(404, 'TRADE_NOT_FOUND', 'Trade not found');
    const notice = typeof request.query === 'object' && request.query && 'ok' in request.query
      ? String((request.query as { ok?: string }).ok)
      : null;
    return view(reply, 'trade-detail', session, { title: detail.trade.reference, active: 'trades', detail, notice });
  });

  app.post('/ops/trades/:id/match', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ops:match');
    const id = (request.params as { id: string }).id;
    const attempt = await tryMatchTrade(ctx, { tradeId: id });
    await audit(ctx, request, session, {
      action: 'trade.match',
      resourceType: 'trade',
      resourceId: id,
      after: attempt,
    });
    return redirect(reply, `/trades/${id}`, attempt.matched ? 'Matched' : attempt.expired ? 'Expired and refunded' : 'Still queued');
  });

  app.post('/ops/matches/:id/disburse', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ops:match');
    const id = (request.params as { id: string }).id;
    const result = await disburseMatch(ctx, { matchId: id });
    await audit(ctx, request, session, {
      action: 'match.disburse',
      resourceType: 'p2p_match',
      resourceId: id,
      after: result,
    });
    const tradeId = result.legs[0]?.trade.id;
    return redirect(reply, tradeId ? `/trades/${tradeId}` : '/', `Match ${result.match.status}`);
  });

  app.post('/ops/trades/:id/recheck', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ops:match');
    const id = (request.params as { id: string }).id;
    const attempt = await ctx.pool.query<{ external_reference: string | null }>(
      `SELECT external_reference FROM payment_attempts
       WHERE trade_id = $1 AND external_reference IS NOT NULL
       ORDER BY created_at DESC LIMIT 1`,
      [id],
    );
    const reference = attempt.rows[0]?.external_reference;
    if (!reference) return redirect(reply, `/trades/${id}`, 'No provider collection to check');
    const collection = await ctx.paymentProvider.getCollection(reference);
    await audit(ctx, request, session, {
      action: 'trade.recheck',
      resourceType: 'trade',
      resourceId: id,
      after: { providerStatus: collection?.status ?? 'not_found' },
    });
    return redirect(
      reply,
      `/trades/${id}`,
      collection ? `Provider says ${collection.status}` : 'Provider has no record',
    );
  });

  app.post('/ops/trades/:id/refund', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'refund:write');
    const id = (request.params as { id: string }).id;
    const reason = normalizeReason(formValue(request.body, 'reason'));
    const result = await refundTrade(ctx, {
      tradeId: id,
      reasonCode: reason,
      allowClosed: false,
    });
    await audit(ctx, request, session, {
      action: 'trade.refund',
      resourceType: 'trade',
      resourceId: id,
      reason,
      after: result,
    });
    return redirect(reply, `/trades/${id}`, `Refund ${result.refund.status}`);
  });

  app.post('/ops/payouts/:id/retry', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'ops:match');
    const id = (request.params as { id: string }).id;
    const payout = await ctx.pool.query<{ trade_id: string }>(
      `SELECT trade_id FROM payouts WHERE id = $1`,
      [id],
    );
    const tradeId = payout.rows[0]?.trade_id;
    if (!tradeId) throw errorWith(404, 'PAYOUT_NOT_FOUND', 'Payout not found');
    const activeMatch = await ctx.pool.query<{ id: string }>(
      `SELECT id FROM p2p_matches
       WHERE status = 'locked' AND (buy_trade_id = $1 OR sell_trade_id = $1)
       ORDER BY created_at DESC LIMIT 1`,
      [tradeId],
    );
    const matchId = activeMatch.rows[0]?.id;
    const result = matchId
      ? await disburseMatch(ctx, { matchId })
      : await startDisbursement(ctx, { tradeId });
    await audit(ctx, request, session, {
      action: 'payout.retry',
      resourceType: 'payout',
      resourceId: id,
      after: result,
    });
    return redirect(
      reply,
      `/trades/${tradeId}`,
      matchId
        ? `Match ${(result as { match: { status: string } }).match.status}`
        : `Payout ${(result as { payout: { status: string } }).payout.status}`,
    );
  });

  app.post('/ops/refunds/:id/retry', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'refund:write');
    const id = (request.params as { id: string }).id;
    const refund = await ctx.pool.query<{ trade_id: string; reason_code: string }>(
      `SELECT trade_id, reason_code FROM refunds WHERE id = $1`,
      [id],
    );
    const row = refund.rows[0];
    if (!row) throw errorWith(404, 'REFUND_NOT_FOUND', 'Refund not found');
    const result = await refundTrade(ctx, {
      tradeId: row.trade_id,
      reasonCode: row.reason_code,
      allowClosed: true,
    });
    await audit(ctx, request, session, {
      action: 'refund.retry',
      resourceType: 'refund',
      resourceId: id,
      after: result,
    });
    return redirect(reply, `/trades/${row.trade_id}`, `Refund ${result.refund.status}`);
  });

  app.get('/audit', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'audit:read');
    const rows = await loadAudit(ctx.pool);
    return view(reply, 'audit', session, { title: 'Audit', active: 'audit', rows });
  });

  app.get('/admin-users', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'admin:users');
    const users = await loadAdminUsers(ctx.pool);
    return view(reply, 'admin-users', session, { title: 'Admin users', active: 'users', users });
  });

  app.post('/admin-users', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'admin:users');
    const email = formValue(request.body, 'email').trim().toLowerCase();
    const name = formValue(request.body, 'name').trim();
    const password = formValue(request.body, 'password');
    const role = formValue(request.body, 'role') as AdminRole;
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || name.length === 0 || password.length < 12) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Name, a valid email and a 12+ character password are required');
    }
    if (!['viewer', 'ops', 'finance', 'compliance', 'superadmin'].includes(role)) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Invalid role');
    }
    const exists = await ctx.pool.query(`SELECT 1 FROM admin_users WHERE email = $1`, [email]);
    if (exists.rowCount) {
      throw errorWith(409, 'ADMIN_USER_EXISTS', 'An admin with that email already exists');
    }
    const id = await createAdminUser(ctx.pool, {
      email,
      name,
      password,
      roles: [role],
      crypto: ctx.crypto,
    });
    await audit(ctx, request, session, {
      action: 'admin_user.create',
      resourceType: 'admin_user',
      resourceId: id,
      after: { email, name, role },
    });
    return redirect(reply, '/admin-users', 'Admin user created');
  });

  app.post('/admin-users/role', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'admin:users');
    const userId = formValue(request.body, 'userId');
    const role = formValue(request.body, 'role') as AdminRole;
    if (!/^[0-9a-f-]{36}$/i.test(userId)) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Choose a user');
    }
    if (!['viewer', 'ops', 'finance', 'compliance', 'superadmin'].includes(role)) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Invalid role');
    }
    const current = await rolesFor(ctx.pool, userId);
    if (current.length === 0) {
      throw errorWith(404, 'ADMIN_USER_NOT_FOUND', 'Admin user not found');
    }
    if (current.includes('superadmin') && role !== 'superadmin') {
      const count = await ctx.pool.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM admin_user_roles WHERE role = 'superadmin'`,
      );
      if (Number(count.rows[0]?.count ?? '0') <= 1) {
        throw errorWith(409, 'ADMIN_LAST_SUPERADMIN', 'The last superadmin cannot lose the role');
      }
    }
    await withTransaction(ctx.pool, async (client) => {
      await client.query(`DELETE FROM admin_user_roles WHERE admin_user_id = $1`, [userId]);
      await client.query(`INSERT INTO admin_user_roles (admin_user_id, role) VALUES ($1, $2)`, [userId, role]);
    });
    await audit(ctx, request, session, {
      action: 'admin_user.role',
      resourceType: 'admin_user',
      resourceId: userId,
      before: { roles: current },
      after: { roles: [role] },
    });
    return redirect(reply, '/admin-users', 'Role updated');
  });

  app.post('/admin-users/:id/status', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'admin:users');
    const id = (request.params as { id: string }).id;
    if (id === session.user.id) {
      throw errorWith(409, 'ADMIN_SELF_ACTION', 'You cannot suspend your own account');
    }
    const status = formValue(request.body, 'status');
    if (!['active', 'suspended'].includes(status)) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Invalid status');
    }
    const roles = await rolesFor(ctx.pool, id);
    if (status === 'suspended' && roles.includes('superadmin')) {
      const count = await ctx.pool.query<{ count: string }>(
        `SELECT count(*)::text AS count
         FROM admin_user_roles r JOIN admin_users u ON u.id = r.admin_user_id
         WHERE r.role = 'superadmin' AND u.status = 'active'`,
      );
      if (Number(count.rows[0]?.count ?? '0') <= 1) {
        throw errorWith(409, 'ADMIN_LAST_SUPERADMIN', 'The last active superadmin cannot be suspended');
      }
    }
    await ctx.pool.query(`UPDATE admin_users SET status = $2 WHERE id = $1`, [id, status]);
    await audit(ctx, request, session, {
      action: 'admin_user.status',
      resourceType: 'admin_user',
      resourceId: id,
      after: { status },
    });
    return redirect(reply, '/admin-users', 'Admin status updated');
  });

  app.post('/admin-users/password', async (request, reply) => {
    const session = request.adminSession as AdminSession;
    requirePermission(session.user.roles, 'admin:users');
    const userId = formValue(request.body, 'userId');
    const password = formValue(request.body, 'password');
    if (!/^[0-9a-f-]{36}$/i.test(userId)) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Choose a user');
    }
    if (password.length < 12) {
      throw errorWith(422, 'ADMIN_USER_INVALID', 'Password must be at least 12 characters');
    }
    const updated = await ctx.pool.query(
      `UPDATE admin_users SET password_hash = $2 WHERE id = $1`,
      [userId, await hashPassword(password)],
    );
    if (!updated.rowCount) throw errorWith(404, 'ADMIN_USER_NOT_FOUND', 'Admin user not found');
    await ctx.pool.query(
      `UPDATE admin_sessions SET revoked_at = now() WHERE admin_user_id = $1 AND revoked_at IS NULL`,
      [userId],
    );
    await audit(ctx, request, session, {
      action: 'admin_user.password_reset',
      resourceType: 'admin_user',
      resourceId: userId,
    });
    return redirect(reply, '/admin-users', 'Password reset and sessions revoked');
  });
}
