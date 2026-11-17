# Admin web portal — implementation

**Status**: Phase A/B portal built 2026-11-16. Phase C live control room,
windowed analytics and read-only bookkeeping built 2026-11-17. Named local
admins, TOTP, sessions, CSRF, RBAC, ops pages and audit are live. SSO,
settlement import and deployment-level IP allowlist remain.
**Code**: `server/src/admin-web/`, `server/scripts/create-admin.ts`
**Tests**: `server/test/admin-web.test.ts`
**Migrations**: `server/db/migrations/0012_admin_identity.sql`,
`server/db/migrations/0013_admin_activity.sql`
**Plan**: `docs/ADMIN_PANEL_PLAN.md`

---

## 1. What this is

A separate `admin-web` process in the same repository/package. It is a
server-rendered internal portal, not a public site and not the Flutter app.

- Runs separately from the customer API (`npm run admin:dev` / `admin:start`).
- Uses the same PostgreSQL database through the normal runtime context.
- Uses its own cookie sessions and `admin_users` identity.
- Serves HTML, CSS and a small JS file. No SPA build step.
- The customer API's env-key `/api/v1/admin/*` remains a **break-glass** surface.
- The customer `/admin` Phase A shell remains in the API for compatibility; the
  portal is the product.

---

## 2. Setup

```bash
cd server
cp .env.example .env
# set DATABASE_URL, DATA_ENCRYPTION_KEY, JWT_SECRET and provider/pricing settings
npm run migrate
npm run seed
npm run admin:create -- --email ops@example.com --name "Ops Admin" --role superadmin
npm run admin:dev
```

`admin:create` prompts for a password, generates TOTP, prints the QR/secret and
ten recovery codes once. It refuses duplicate emails and requires a 12+
character password. When stdin is not a TTY it reads `ADMIN_PASSWORD`.

Portal environment:

```bash
ADMIN_WEB_PORT=3001
ADMIN_WEB_HOST=127.0.0.1
ADMIN_BASE_URL=https://admin.example.com
ADMIN_COOKIE_SECURE=true
ADMIN_SESSION_TTL_SECONDS=28800
ADMIN_TOTP_ISSUER=CrossPay Admin
```

`ADMIN_BASE_URL` is used for origin checks and should be the public HTTPS origin.
`ADMIN_COOKIE_SECURE` defaults to true when the base URL is HTTPS or
`NODE_ENV=production`.

Production build:

```bash
npm run build
npm run admin:start
```

The build copies `views/` and `public/` into `dist/admin-web/`. It replaces the
previous asset copy, so repeated builds cannot nest `public/public`.

---

## 3. Authentication flow

1. `POST /login` verifies the email and Argon2id password.
2. If TOTP is not enrolled, the user is sent to `/setup-totp` with a short-lived
   challenge. The secret is encrypted in `admin_login_challenges`; the QR and
   manual secret are shown once.
3. If TOTP is enrolled, the user is sent to `/login/totp`.
4. A valid six-digit code creates a server-side session:
   - random token in an `HttpOnly`, `SameSite=Strict`, `Secure` cookie;
   - only the SHA-256 token hash is stored;
   - the session row holds the CSRF token and expiry (8 hours by default).
5. TOTP replay is rejected by `admin_users.totp_last_step`.
6. Failed logins are counted per email/IP; 10 failures in 15 minutes blocks the
   account/IP for the window.
7. Logout revokes the session row and clears the cookie.

No customer JWT is accepted by the portal.

---

## 4. CSRF and origin checks

- Every authenticated state-changing form carries `_csrf` matching the session.
- `preValidation` rejects a missing/invalid token with `403`.
- If an `Origin` header is present it must match `ADMIN_BASE_URL`.
- Cookies are `SameSite=Strict`.
- The portal sets:
  - `Content-Security-Policy` (self only, data images for QR, no frames);
  - `X-Frame-Options: DENY`;
  - `X-Content-Type-Options: nosniff`;
  - `Referrer-Policy: no-referrer`;
  - `X-Robots-Tag: noindex, nofollow`;
  - HSTS when served over HTTPS.

---

## 5. Roles

| Role | Access |
|---|---|
| `viewer` | read-only overview, control room, analytics, trades |
| `ops` | viewer + match/disburse/recheck/payout retry, corridor policy |
| `finance` | viewer + LP providers/orders + refunds |
| `compliance` | viewer + audit |
| `superadmin` | everything, admin-user management |

The role map is in `src/admin-web/auth.ts`. Named users can have multiple roles.
The last active superadmin cannot be suspended or demoted.

---

## 6. Pages

| Page | What it does |
|---|---|
| `/` | KPIs, alerts, corridors, queue, matches, payouts/refunds, LP orders, oldest-work ages |
| `/control-room` | Live SSE feed with source filter/pause plus 5-second snapshot fallback, alerts, corridors, queue health, recent admin actions |
| `/analytics` | `24h`/`7d`/`30d`/`all` windows: status/corridor, funnel, fee and spread revenue, provider success, refund reasons, payouts, refunds, LP |
| `/bookkeeping` | Debit-positive trial balance per currency and filterable journal browser (finance/compliance/superadmin) |
| `/bookkeeping/journals/:id` | Journal lines, balance check, reversal links and linked FX partner journals |
| `/corridors` | enable/cap/min/max/deadline/estimate/spread forms |
| `/liquidity` | providers, prefunded orders, create/cancel |
| `/trades` | search by reference, phone, beneficiary last 4 |
| `/trades/:id` | timeline, attempts, payouts, refunds, ledger lines, safe actions |
| `/audit` | append-only admin audit (compliance/superadmin) |
| `/admin-users` | create user, set role, suspend, reset password (superadmin) |

Ops actions are server-authoritative and audited:

- re-check the provider (read-only, no state change);
- try a match;
- resume a match payout;
- retry a pending payout;
- refund (finance/ops), provider-confirmed;
- retry a pending refund.

---

## 7. Live activity and analytics

Migration `0013` adds `admin_activity_events`, an append-only outbox written by
database triggers, not application code. Every process that changes money or
policy therefore feeds the same stream, including the API, the worker and any
future support tool.

| Source | Written from |
|---|---|
| `trade` | `trade_events` inserts |
| `match` | `p2p_matches` insert/status changes |
| `payout` | `payouts` insert/status changes |
| `refund` | `refunds` insert/status changes |
| `liquidity` | `liquidity_orders` insert/status changes |
| `admin` | `admin_audit_log` inserts |

The payload carries references, statuses, currencies and minor amounts only.
Recipient names, phone numbers and account numbers never enter the activity
table. Updates and deletes on the table are rejected by a trigger.

The control room:

- loads the latest 60 events for the initial snapshot;
- opens `GET /control-room/stream?after=<snapshot id>` (SSE) and resumes from
  `Last-Event-ID` or `after`; a fresh stream never replays the whole outbox;
- shares one 2-second database poller across all connected browsers, with a
  monotonic id cursor, a 10-second overlap and id deduplication so a late commit
  is not skipped;
- sends a heartbeat every 15 seconds and asks the browser to reconnect after
  10 minutes;
- falls back to the 5-second `/control-room/data` snapshot if SSE fails;
- supports source filtering and pause, with a buffered count while paused.

The `pg_notify('admin_activity', id)` trigger is installed for a later
`LISTEN/NOTIFY` transport; the current transport is bounded polling.

Analytics counts completed trades only, exposes a funnel by send currency, and
reads revenue from ledger accounts `3000` (fee) and `3100` (spread). Provider
fees (`6000`) and compensation (`6100`) are shown as separate costs. Minor units
are never summed across currencies.

---

## 8. Bookkeeping

The bookkeeping pages are read-only and require `ledger:read` (finance,
compliance, superadmin):

- trial balance is debit-positive, grouped by currency, and shows whether each
  currency's debits equal its credits;
- journal browser filters by currency, kind and trade reference;
- journal detail shows every line, the balance check, reversals, and FX partners
  linked through `fx_group_id`;
- there is deliberately no “mark as paid”, journal editor, delete, or SQL
  console.

The two linked FX journals are displayed together, but their minor units are
never added: each journal is single-currency by construction.

Bank/PSP statement import and matching are **not connected**. The page says so
and never labels a ledger balance “matched” against a real account.

---

## 9. Current limitations

- No SSO yet; local accounts + TOTP only.
- No recovery-code **login** flow; a superadmin resets TOTP by resetting the
  account or the CLI/database, and recovery codes are stored hashed.
- The control room transport is 2-second polling + SSE, not database
  `LISTEN/NOTIFY` consumption. The notify trigger is ready for that change.
- Analytics is server-rendered tables; charts and saved views are later.
- Configuration center (fees/services/tiers/flags) is Phase D.
- Settlement/reconciliation and support cases are later phases. Bookkeeping is
  ledger-only until a statement source exists.
- IP allowlist/VPN/zero-trust is deployment configuration, not application code.
- The env-key `/api/v1/admin/*` remains a break-glass surface until it is
  retired or restricted.

---

## 10. Tests

`server/test/admin-web.test.ts` covers:

- anonymous redirect and login page;
- password + TOTP login and overview;
- TOTP replay rejection;
- CSRF rejection and successful corridor update;
- RBAC: viewer cannot write;
- control-room data and trade search;
- trigger-fed activity visible in the control-room snapshot and delivered by a
  short-interval `ActivityStream` poller;
- SSE resume from `after`/`Last-Event-ID` without replaying older activity;
- analytics window tabs, revenue and funnel sections;
- bookkeeping trial balance and journal detail with a posted opening journal;
- named admin creation and last-superadmin self-protection;
- first-login TOTP enrolment and recovery-code display;
- audit rows with the acting admin id.

Suite after this phase: **102/102**, 20 suites, typecheck clean.

---

## 11. Deployment

- Run `admin-web` as its own container/process with the same image as the API
  but `node dist/admin-web/server.js`.
- Put it behind a zero-trust proxy (Cloudflare Access / Google IAP / Tailscale)
  or VPN; add IP allowlist where stable.
- Use a separate hostname (`admin.example.com`), TLS, WAF, noindex.
- Use a least-privilege database role; it does not run migrations.
- Set `ADMIN_BASE_URL` to the public HTTPS origin and `ADMIN_COOKIE_SECURE=true`.
- Keep `ADMIN_API_KEY` unset in normal production if the portal is the only admin
  surface; use it only as a documented break-glass path.
- Monitor 5xx, login failures, TOTP failures, audit insert failures, session
  table growth and `admin_activity_events` growth. The outbox is append-only, so
  retention needs an explicit partitioned-table/export decision rather than an
  ad-hoc delete.
- The control room SSE holds one connection per browser. The shared poller keeps
  database load flat, but put the portal behind a proxy that does not buffer
  `text/event-stream`.
