# Admin web portal — implementation

**Status**: Phase A/B portal built 2026-11-16. Named local admins, TOTP, sessions,
CSRF, RBAC, ops pages and audit are live. SSO and deployment-level IP allowlist
remain.
**Code**: `server/src/admin-web/`, `server/scripts/create-admin.ts`
**Tests**: `server/test/admin-web.test.ts`
**Migration**: `server/db/migrations/0012_admin_identity.sql`
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

The build copies `views/` and `public/` into `dist/admin-web/`.

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
| `/` | KPIs, alerts, corridors, queue, matches, payouts/refunds, LP orders |
| `/control-room` | 5-second polling snapshot + live activity feed + recent admin actions |
| `/analytics` | trades by status/currency, completed corridors, payouts, refunds, LP |
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

## 7. Current limitations

- No SSO yet; local accounts + TOTP only.
- No recovery-code **login** flow; a superadmin resets TOTP by resetting the
  account or the CLI/database, and recovery codes are stored hashed.
- The control room polls every 5 seconds; SSE/event outbox is Phase C.
- Analytics is table-based; charts/export jobs are Phase C.
- Configuration center (fees/services/tiers/flags) is Phase D.
- Bookkeeping, settlement/reconciliation and support cases are later phases.
- IP allowlist/VPN/zero-trust is deployment configuration, not application code.
- The env-key `/api/v1/admin/*` remains a break-glass surface until it is
  retired or restricted.

---

## 8. Tests

`server/test/admin-web.test.ts` covers:

- anonymous redirect and login page;
- password + TOTP login and overview;
- TOTP replay rejection;
- CSRF rejection and successful corridor update;
- RBAC: viewer cannot write;
- control-room data and trade search;
- named admin creation and last-superadmin self-protection;
- first-login TOTP enrolment and recovery-code display;
- audit rows with the acting admin id.

Suite after this phase: **100/100**, 20 suites, typecheck clean.

---

## 9. Deployment

- Run `admin-web` as its own container/process with the same image as the API
  but `node dist/admin-web/server.js`.
- Put it behind a zero-trust proxy (Cloudflare Access / Google IAP / Tailscale)
  or VPN; add IP allowlist where stable.
- Use a separate hostname (`admin.example.com`), TLS, WAF, noindex.
- Use a least-privilege database role; it does not run migrations.
- Set `ADMIN_BASE_URL` to the public HTTPS origin and `ADMIN_COOKIE_SECURE=true`.
- Keep `ADMIN_API_KEY` unset in normal production if the portal is the only admin
  surface; use it only as a documented break-glass path.
- Monitor 5xx, login failures, TOTP failures, audit insert failures and session
  table growth.
