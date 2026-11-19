# Admin web portal — implementation

**Status**: Phase A/B portal built 2026-11-16. Phase C live control room,
windowed analytics and read-only bookkeeping built 2026-11-17. Manual support
workspace with audited PII reveal built 2026-11-17. Phase D configuration center
(versioned proposals, two-person approval, emergency service controls) built
2026-11-18. Phase F reconciliation v1 (manual statements, exact matching,
exceptions, daily close) built 2026-11-18. Compliance KYC review queue built
2026-11-19. Recovery-code login, statement file upload and the app maintenance
banner were added 2026-11-19. The same day added linked reconciliation
corrections, localized scheduled app banners and a `LISTEN/NOTIFY` control-room
transport. Named local admins, TOTP, sessions, CSRF, RBAC, ops pages and audit
are live. SSO, live statement feeds, sanctions screening and deployment-level
IP allowlist remain.
**Code**: `server/src/admin-web/`, `server/scripts/create-admin.ts`
**Tests**: `server/test/admin-web.test.ts`
**Migrations**: `server/db/migrations/0012_admin_identity.sql`,
`server/db/migrations/0013_admin_activity.sql`,
`server/db/migrations/0014_support_workspace.sql`,
`server/db/migrations/0015_configuration_center.sql`,
`server/db/migrations/0016_settlement_reconciliation.sql`,
`server/db/migrations/0017_reconciliation_missing_lines.sql`,
`server/db/migrations/0018_kyc_review.sql`,
`server/db/migrations/0019_trade_invoices.sql`,
`server/db/migrations/0020_reconciliation_corrections.sql`,
`server/db/migrations/0021_app_banners.sql`
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
4. A valid unused recovery code at `/login/recovery` can replace the TOTP step.
   The code is consumed atomically and the recovery login is audited.
5. A valid six-digit code creates a server-side session:
   - random token in an `HttpOnly`, `SameSite=Strict`, `Secure` cookie;
   - only the SHA-256 token hash is stored;
   - the session row holds the CSRF token and expiry (8 hours by default).
6. TOTP replay is rejected by `admin_users.totp_last_step`.
7. Failed logins are counted per email/IP; 10 failures in 15 minutes blocks the
   account/IP for the window.
8. Logout revokes the session row and clears the cookie.

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
| `viewer` | read-only overview, control room, analytics, trades; no support cases or configuration |
| `ops` | viewer + match/disburse/recheck/payout retry, corridor policy, support cases/notes/SMS, configuration proposals |
| `finance` | viewer + LP providers/orders + refunds + bookkeeping, configuration proposals/approvals, reconciliation import/resolve/close; no support cases |
| `compliance` | viewer + audit + bookkeeping + reconciliation read + KYC review + support cases + customer PII reveal; no configuration |
| `superadmin` | everything, including admin-user management, PII reveal, config approval and emergency service controls |

The role map is in `src/admin-web/auth.ts`. Named users can have multiple roles.
The last active superadmin cannot be suspended or demoted.

---

## 6. Pages

| Page | What it does |
|---|---|
| `/` | KPIs, alerts, corridors, queue, matches, payouts/refunds, LP orders, oldest-work ages |
| `/control-room` | Live SSE feed with source filter/pause plus 5-second snapshot fallback, alerts, corridors, queue health, recent admin actions |
| `/analytics` | `24h`/`7d`/`30d`/`all` windows: status/corridor, funnel, fee and spread revenue, provider success, refund reasons, payouts, refunds, LP |
| `/config` | emergency service controls, pending/decided config changes, support contacts, tier daily limits, provider-observed fee bps, version history |
| `/config/changes/:id` | immutable before/after diff, approve/reject/cancel, propose rollback |
| `/bookkeeping` | Debit-positive trial balance per currency and filterable journal browser (finance/compliance/superadmin) |
| `/bookkeeping/journals/:id` | Journal lines, balance check, reversal links and linked FX partner journals |
| `/reconciliation` | statement summary, manual CSV import, provider/bank statement list and open-exception count |
| `/reconciliation/statements/:id` | statement lines, exact matches, exceptions, resolve and daily close |
| `/compliance/kyc` | KYC queue by status with masked customer identity and identity last4 |
| `/compliance/kyc/:id` | KYC metadata, verification history, approve/reject with reason |
| `/corridors` | enable/cap/min/max/deadline/estimate/spread forms |
| `/liquidity` | providers, prefunded orders, create/cancel |
| `/trades` | search by reference, phone, beneficiary last 4 |
| `/trades/:id` | timeline, attempts, payouts, refunds, ledger lines, safe actions, open support case |
| `/support` | case queue with status/priority/assignee filters and masked customer identity |
| `/support/new` | open a case from a customer, optionally attached to one trade |
| `/support/cases/:id` | case detail, append-only notes, SMS reply, state/assignee, audited PII reveal |
| `/support/customers/:id` | customer 360: masked identity, cases, recent trades |
| `/support/canned` | operator-managed reply templates, create/activate/deactivate |
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
| `support` | case insert/status/priority/assignee, message insert/delivery, PII reveal |
| `config` | config change proposed/decided, emergency service controls updated |
| `reconciliation` | statement imported/closed, exception resolved |
| `compliance` | KYC approved/rejected |
| `admin` | `admin_audit_log` inserts (support/config/reconciliation/KYC resources are de-duplicated) |

The payload carries references, statuses, currencies and minor amounts only.
Recipient names, phone numbers, account numbers, case subjects and message
bodies never enter the activity table. Support message events record only the
channel, visibility, delivery state and body length. Updates and deletes on the
activity table are rejected by a trigger.

The control room:

- loads the latest 60 events for the initial snapshot;
- opens `GET /control-room/stream?after=<snapshot id>` (SSE) and resumes from
  `Last-Event-ID` or `after`; a fresh stream never replays the whole outbox;
- shares one database poller across all connected browsers, with a monotonic id
  cursor, a 10-second overlap and id deduplication so a late commit is not
  skipped;
- keeps a dedicated `LISTEN admin_activity` connection while any stream is
  open. The outbox trigger's `pg_notify` wakes the poller immediately; the
  2-second interval remains as the fallback for missed notifications,
  reconnects and late commits. The listener reconnects after 5 seconds and
  holds one pool connection, not one per browser;
- sends a heartbeat every 15 seconds and asks the browser to reconnect after
  10 minutes;
- falls back to the 5-second `/control-room/data` snapshot if SSE fails;
- supports source filtering and pause, with a buffered count while paused.

The tests prove both paths: a one-minute fallback interval still delivers a new
event immediately through `LISTEN`, and a deliberately broken listener still
delivers through the polling fallback.

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

## 9. Configuration center

Migration `0015` adds versioned configuration and emergency service controls.
Nothing here edits source code or writes a journal directly.

**Versioned proposals**

- Support contacts (`support_settings`) and tier daily limits (`tier_limits`)
  use a proposal → approval workflow in `admin_config_changes`.
- A proposal stores immutable `before`/`after` JSON, the proposer, a reason and
  a `CS-…`-style audit trail. The database guard rejects rewriting the payload
  after creation.
- Only one pending change per setting is allowed. A competing proposal gets
  `409 CONFIG_CHANGE_CONFLICT`.
- `config:propose` is available to ops, finance and superadmin.
  `config:approve` is finance/superadmin. The proposer cannot approve their own
  change; a different named admin must do it.
- Approval applies the value and publishes the next `config_versions` row in the
  same transaction. Rejection or cancellation never applies the value.
- “Rollback” creates a new pending proposal using the previous value; it is not
  a silent write. It still needs a second admin.
- Support contacts can be removed by submitting an empty block. Tier limits can
  be removed with a blank limit; a missing limit blocks trades rather than
  inventing a limit.
- Tier limits are enforced only when the account's limit currency matches the
  trade currency. There is no FX conversion of limits.

**Emergency service controls**

- `service_controls` holds `quotesPaused`, `tradesPaused` and a short message.
- Only a superadmin can change it, and it applies immediately: an incident must
  not wait for a second approver. Every change is audited and emitted to the
  control room.
- `POST /trade/quote` returns `503 SERVICE_PAUSED` while quotes are paused.
  `POST /trade/initiate` returns the same while trades are paused.
- Rates, estimates, existing payouts, refunds and matches keep running. This is
  a drain switch, not a full stop.
- `GET /config` includes an optional `service` block while a pause or message is
  active. The Flutter app renders it as a banner above the signed-in tabs.

**Localized scheduled banners**

- Published banners live in `app_banners`; every change is an
  `admin_config_changes` row with key `app_banner:<uuid>`, so the same
  proposer/approver rule and append-only history apply. An update keeps the
  banner id; approval updates the row in place.
- Each banner carries English and Swahili text (5–200 characters each), an
  `info | warning | critical` severity, and a UTC window. A window must be
  positive and at most 90 days, may start at most 180 days ahead, and must end
  in the future.
- `GET /config.banners` includes only banners whose window contains the current
  server time (`startsAt` inclusive, `endsAt` exclusive). The Flutter shell
  re-checks the window, chooses the selected language and falls back to English
  if the Swahili text is blank.
- Removal is also a proposal (`POST /config/banners/:id/remove`): approval
  deletes the banner. A rollback of the creating or removal change restores the
  previous published payload.
- The admin page lists active/upcoming/ended state, supports editing a banner
  without changing its id, and shows human-readable before/after values instead
  of raw JSON.
- This is not the emergency drain switch. Emergency pauses stay immediate and
  superadmin-only; scheduled banners always need a second approver.

**Fees stay provider-owned**

- Quote `feeBps`, `feeMinor` and `totalDebitMinor` come from the pricing
  provider and are persisted in the quote snapshot. The admin does not override
  them, because a second fee source could disagree with the quote the customer
  already accepted.
- The configuration page shows the declared policy (P2P 150 bps, bank 250 bps)
  against provider-observed fee bps from the last seven days. A mismatch is
  labelled, not silently “corrected”.
- A fee editor is intentionally deferred until the provider fee contract is
  reconciled and the quote path reads one versioned source.

---

## 10. Support workspace

Migration `0014` adds manual case management. It is not an in-app chat and does
not pretend to be one: the Flutter support screen can only copy request details
today.

- A case belongs to one customer and optionally one trade. The database refuses
  a trade that belongs to a different customer.
- Cases have a stable `CS-YYMMDD-XXXXXX` reference, category, priority, status,
  assignee, opening channel and first-response timestamp.
- Case messages are append-only. Notes are internal; SMS replies are
  customer-visible. A trigger rejects rewriting the body or author of a message.
  The only mutable field is SMS delivery state (`pending` → `sent`/`failed`).
- Canned replies are operator-managed plain text. They are never sent
  automatically and placeholders are not expanded.
- The customer phone is masked to the last four digits throughout the support
  screens. The beneficiary name and last four are visible; the full phone and
  encrypted beneficiary account are not.
- Customer 360 shows masked identity, open/total cases and recent trades.
- PII reveal requires `pii:reveal` (compliance/superadmin), a 5-300 character
  reason, and writes both `support_pii_reveals` (append-only) and
  `admin_audit_log`. The response is `no-store`; the control room records a
  warning event with field names only.
- Customer SMS replies require an SMS provider. With `SMS_PROVIDER=disabled`
  the request returns an honest `503 SMS_NOT_CONFIGURED` and records nothing.
  With a provider, the message row is written as `pending` before delivery,
  then `sent` or `failed`. A failed reply keeps its text and failure code so the
  operator can copy it; it is never marked sent.
- Support actions never mark a payment paid, edit a journal, promise a refund or
  bypass KYC. They call only support services and leave money actions to the
  trade/refund screens.

---

## 11. Reconciliation v1

Migration `0016` adds manual settlement statements, immutable statement lines,
exceptions and a per-statement daily close. This is evidence review, not a
ledger editor and not a bank feed.

**Import**

- Finance/superadmin upload one CSV file (or paste it) at `/reconciliation`, max
  5,000 lines / 2 MB. Required columns:
  `occurred_at,reference,kind,amount_minor,currency`. Optional:
  `posting_key,description`.
- Kinds: `collection,payout,refund,fee,transfer,adjustment`.
- A statement is one source (`provider` or `bank`), one currency and one derived
  period. The file hash is unique per source/currency, so the same export cannot
  be imported twice.
- Lines are append-only. The statement header is immutable except for close
  state. There is no re-run that rewrites history.

**Matching**

- `collection`: payment attempt by provider + reference; must be `confirmed`,
  amount/currency equal, and have a `deposit_received` journal.
- `payout`/`refund`: provider reference; must be `paid`, amount/currency equal,
  and have its `payout_sent`/`refund_paid` journal.
- `fee`/`transfer`/`adjustment`, and every bank line: require an explicit
  CrossPay `posting_key`. The journal must be in the same currency and its debit
  total must equal the line amount.
- Provider imports also look for internal confirmed collections and paid
  payouts/refunds in the same period/currency whose reference is absent from the
  statement. Those become `missing_in_statement` exceptions against the internal
  row; they are separate from the statement line count.
- Errors become typed exceptions: `unmatched_reference`, `amount_mismatch`,
  `currency_mismatch`, `status_mismatch`, `missing_journal`,
  `duplicate_reference`, `unmatched_journal`, `unsupported_line`,
  `missing_in_statement`.
- Nothing is auto-corrected and no line is marked matched without both the
  provider evidence and a journal.

**Exceptions and close**

- An exception can be resolved once with a 5-300 character note. Resolution
  records that the item was investigated; it does not write off money or edit a
  journal.
- Finance/superadmin close a statement only when every exception is resolved.
  A close note is required, closing is final, and the resolved exception count
  remains visible.
- Compliance can read statements and exceptions; only finance/superadmin can
  import, resolve or close.

**Corrections (v1.1)**

Migration `0020` adds linked corrections. A closed statement is never reopened,
mutated or deleted.

- The import form can name a closed statement to correct and requires a
  10-300 character reason. The original must be closed and have the same source
  kind, source label, provider and currency; otherwise the import is rejected
  (`STATEMENT_CORRECTION_ORIGINAL_OPEN` 409, `STATEMENT_CORRECTION_MISMATCH`
  422, `CORRECTION_REASON_INVALID` 422).
- The correction is a new statement with its own file hash, lines, exceptions
  and close decision. `corrects_statement_id` and the reason are immutable.
- Both statements are cross-linked: the correction shows the original, and the
  original shows every statement that corrects it.
- The control room gets a `statement.corrected` event with the link and reason;
  audit records the same linkage. It carries no customer data.

**Not connected in v1**

- No live provider API or bank feed; CSV file upload/paste is manual.
- Provider statements check both directions: statement → internal record →
  journal, and internal record missing from the statement. Bank statements only
  check the posting-key direction; bank-side missing detection is not built.
- No automatic fee-line matching without a posting key, no manual journal
  posting and no statement-level CSV export.
- Closing does not assert a bank balance matched.

---

## 12. KYC review

Migration `0018` adds a manual compliance queue over the existing
`kyc_verifications` table.

- `/compliance/kyc` lists pending, verified or rejected submissions. Pending is
  oldest-first. Customer phone is masked to the last four digits.
- The reviewer sees legal name, account type/hub, ID type and last four digits.
  The full identity number stays encrypted and is **never decrypted** by this
  screen. There is no document image or name-check provider result in the
  repository.
- Approval changes the verification to `verified` and the customer to
  `kyc_status='verified'` in one transaction. Rejection requires a rejection
  code and a 5-300 character note, and changes both rows to `rejected`.
- Only a pending verification can be decided; the decided row is immutable.
  The customer can submit a new KYC application after a rejection.
- Reviewer, decision time and note are stored on the row and in admin audit.
  Control-room activity carries status, account/ID type and rejection code,
  never the legal name or identity number.
- Daily limits are not changed by KYC approval. They still come from the
  versioned tier/currency limit.

---

## 13. Current limitations

- No SSO yet; local accounts + TOTP or a one-time recovery code.
- Analytics is server-rendered tables; charts and saved views are later.
- Configuration center v1 covers support contacts, tier daily limits, localized
  scheduled app banners and emergency quote/trade pauses. Fee bps, provider
  secrets/endpoints, feature flags, generic effective-date scheduling and
  per-corridor fee overrides are not editable yet.
- Reconciliation is manual. Provider statements check both directions; bank
  statements only check lines with a posting key, and bank-side missing
  detection is not built. No provider API, bank feed, automatic fee matching
  without a posting key or bank balance matching. Corrections are linked new
  statements, never re-opens.
- Support is a manual case workspace: no customer-facing chat, no email/WhatsApp
  outbound, no attachments, no CSAT survey and no automated replies. SMS is the
  only outbound channel and requires a configured provider.
- A process crash between writing a pending SMS row and calling/updating the
  gateway leaves the row `pending`; there is no retry worker for that state yet.
- KYC review is manual metadata only: no document images, OCR, name-check
  provider, sanctions screening or watchlist data. Sanctions queues are not
  built. Approval cannot bypass the pending state.
- IP allowlist/VPN/zero-trust is deployment configuration, not application code.
- The env-key `/api/v1/admin/*` remains a break-glass surface until it is
  retired or restricted.

---

## 14. Tests

`server/test/admin-web.test.ts` covers:

- anonymous redirect and login page;
- password + TOTP login and overview;
- TOTP replay rejection;
- CSRF rejection and successful corridor update;
- RBAC: viewer cannot write;
- control-room data and trade search;
- trigger-fed activity visible in the control-room snapshot, delivered
  immediately through `LISTEN admin_activity` with a one-minute fallback
  interval, and still delivered through polling when the listener is broken;
- SSE resume from `after`/`Last-Event-ID` without replaying older activity;
- analytics window tabs, revenue and funnel sections;
- bookkeeping trial balance and journal detail with a posted opening journal;
- support case creation, masked phone, append-only notes, state/assignee update,
  viewer denial, canned reply create/deactivate and control-room activity that
  excludes message bodies;
- configuration proposals for support contacts and tier limits, two-person
  approval, self-approval denial, one-pending-change conflict, rollback,
  published config versions and config activity without payload values;
- localized scheduled banners: validation, readable change pages, same-id
  edits, two-person approval, active-only `/config.banners`, upcoming/expired
  filtering, removal proposals and rollback restore;
- emergency service controls, `SERVICE_PAUSED` enforcement on quote and trade
  initiation, and the optional `/config.service` block;
- reconciliation import, exact payout matching, unmatched/amount/duplicate
  exceptions, bank posting-key matching, mixed-currency rejection,
  missing-in-statement detection, blocked close, exception resolution, final
  close, duplicate-file rejection and reconciliation activity without notes;
- linked corrections of closed statements: the original stays closed and
  unchanged, mismatched source/kind/currency is rejected, the reason is
  required, and both statements show the link;
- KYC queue RBAC, masked identity, no full identity number in HTML, approval
  updating the customer, repeat-decision rejection, rejection code/note
  validation and redacted compliance activity;
- PII reveal denied without `pii:reveal`, allowed with a reason for compliance,
  recorded in `support_pii_reveals`/audit/activity without the values;
- SMS reply refused when no provider is configured, recorded as `sent` when the
  gateway accepts it and `failed` when the gateway rejects it;
- recovery-code login, one-time consumption, audit and reuse rejection;
- reconciliation multipart CSV upload;
- named admin creation and last-superadmin self-protection;
- first-login TOTP enrolment and recovery-code display;
- audit rows with the acting admin id.

Suite after this phase: **121/121**, 21 suites, typecheck clean.

---

## 15. Deployment

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
  table growth, `admin_activity_events` growth, support rows stuck in `pending`,
  open reconciliation exceptions and alert on `service_controls` pauses that
  outlive an incident. The activity outbox is append-only, so retention needs an
  explicit partitioned-table/export decision rather than an ad-hoc delete.
- The control room SSE holds one connection per browser. The shared poller keeps
  database load flat, but put the portal behind a proxy that does not buffer
  `text/event-stream`.
