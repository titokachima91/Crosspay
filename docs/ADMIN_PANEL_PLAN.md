# CrossPay admin panel — plan

**Status**: plan, 2026-11-16. Phase A and the local-account Phase B portal are
built (`docs/ADMIN_WEB_IMPLEMENTATION.md`). SSO, control room/analytics,
configuration center, bookkeeping, settlement and support/compliance remain.
**Related**: `docs/REVENUE_AND_BOOKKEEPING.md`, `docs/B4_MATCHING_IMPLEMENTATION.md`,
`docs/B1_DATABASE_PLAN.md`, `docs/api_contract.md`

---

## 1. What the admin panel is

The crosspay admin panel is **not** a second customer app and **not** a direct
database console. It is the controlled operational surface for:

1. **Live payments ops** — funded queue, matches, payouts, refunds, incidents.
2. **Control room** — a real-time, redacted feed of what is happening across the
   app: sign-ins, quotes, trades, provider callbacks, payouts, failures,
   support actions and admin actions.
3. **Analytics** — funnel, corridor, provider, revenue, liquidity and support
   metrics, always separated by currency.
4. **Configuration and control** — services, fees, spreads, corridors, tiers,
   provider settings, feature flags and maintenance state.
5. **Corridor and liquidity policy** — enablement, caps, deadlines, LP orders.
6. **CrossPay bookkeeping** — its own income, costs, treasury funding and
   settlement into its normal bank/PSP operating accounts.
7. **Reconciliation** — provider statements, bank/PSP operating accounts and
   CrossPay's ledger, with an exceptions queue.
8. **Support workspace** — customer-safe lookup, case notes, explanations and
   safe actions to resolve a customer's issue.
9. **Compliance** — KYC/name-check review, sanctions, PII reveal and audit, later.

It never holds customer cash, never edits ledger history, and never exposes a
customer's full PII without a permissioned, audited reveal.

---

## 2. Non-negotiable principles

1. **Customer funds are not CrossPay funds.** Partner trust/escrow cash is a
   liability-backed pool; CrossPay's own money sits in operating accounts.
2. **Ledger history is append-only.** An admin action posts a journal or a
   reversal; it never updates or deletes one.
3. **No cross-currency arithmetic.** Every screen and report is scoped to one
   currency or shows separate currency rows. Minor units are never summed
   across currencies.
4. **Every money action is idempotent, authorized, reasoned and audited.**
5. **Read and write are separate permissions.** A viewer can see the queue;
   only an operator can match; only finance can approve a manual adjustment.
6. **Two people for dangerous actions.** Manual payouts, refunds above a
   threshold, ledger adjustments, LP prefund corrections and chart-of-accounts
   changes require a second approver.
7. **No silent automation.** When the system cannot do something, the panel
   shows the honest reason and the provider code.
8. **The sandbox is a simulator.** Its `CROSSPAY` revenue mirror is testing-only
   and must not be used by the admin.
9. **Configuration is data, versioned and approved.** Fees, spreads, limits and
   feature switches live in tables with effective dates, validation, audit and
   rollback — never in source code.
10. **Real-time oversight is privacy-preserving.** The control room shows
    references, corridors, statuses and masked identifiers; full PII requires a
    permissioned reveal with a reason.
11. **Support can help without breaking the money rules.** Support can re-check
    a provider, resend a receipt, cancel a pending trade, reset a session or
    add a note; support can never mark a payment paid, edit a ledger, bypass KYC
    or reveal another person's data.

---

## 3. Phases

| Phase | Scope | Gate |
|---|---|---|
| A. Ops read + narrow controls | Overview, queue, matches, payouts, refunds, corridors, LP orders; env admin key; audit writes | Built |
| B. Admin identity and RBAC | Admin users, passwords + TOTP, sessions, roles, CSRF, IP allowlist, audit log UI | Built for local accounts; SSO/IP allowlist are deployment follow-ups |
| C. Control room and analytics | Real-time redacted activity feed, SLOs, funnel/corridor/provider/liquidity/support analytics, saved views, exports | Built for feed/windows/funnel/revenue; saved views and charts remain |
| D. Configuration center | Services, fees, spreads, tiers/limits, provider settings, feature flags, maintenance, staged rollout/rollback | Versioned approval for support contacts/tier limits and emergency quote/trade pauses built; fee editor, provider secrets, flags/banners and effective dates remain |
| E. Bookkeeping | Chart approval, journal browser, trial balance, revenue/cost reports, operating-cash transfers | Read-only journal browser/trial balance built; chart approval and reports remain |
| F. Settlement and reconciliation | Provider statements, bank/PSP statement import or API, matching, exceptions, daily close | Manual CSV import, exact reference/journal matching, provider missing-in-statement detection, exceptions and final close built; live feeds, bank balance matching and bank-side missing detection remain |
| G. Support and compliance | Customer-safe support workspace, cases/notes, KYC queue, sanctions hits, PII reveal workflow | Manual cases/notes/SMS/PII reveal built; KYC and sanctions queues remain |
| H. Sandbox mirror removal | Remove testing-only `CROSSPAY` book and docs | E and F pass in production/sandbox |

The B4.6 work in this phase is **A and B (local accounts) only**. It is
deliberately read-heavy and does not pretend to be the final admin.

---

## 4. Roles and permissions

| Permission | viewer | ops | finance | compliance | superadmin |
|---|---|---|---|---|---|
| View overview/queue/matches | yes | yes | yes | yes | yes |
| View control room/analytics | yes | yes | yes | yes | yes |
| View trade amounts/status | yes | yes | yes | yes | yes |
| Reveal customer PII | no | no | no | yes | yes |
| Edit services/fees/spreads/tiers | no | propose | approve | no | yes |
| Enable/disable corridor | no | yes | no | no | yes |
| Change corridor caps/deadlines | no | propose | approve | no | yes |
| Create/suspend LP provider | no | propose | approve | no | yes |
| Create/cancel LP order | no | propose | approve | no | yes |
| Trigger match/disburse retry | no | yes | no | no | yes |
| Support case read/write | no | yes | no | yes | yes |
| Customer-safe support actions | no | yes | no | yes | yes |
| Refund below threshold | no | yes | yes | no | yes |
| Refund above threshold | no | propose | approve | no | yes |
| Manual journal/adjustment | no | no | propose | no | approve |
| Journal/trial-balance read | no | yes | yes | yes | yes |
| Reconciliation close | no | no | yes | no | yes |
| Audit-log read | no | own actions | own actions | yes | yes |
| Admin-user management | no | no | no | no | yes |

Thresholds and permissions live in configuration, not source constants.
The initial env-key dashboard is a **break-glass/viewer** bridge and must be
replaced before production money actions.

---

## 5. Authentication and security

### Phase A (current)

- `ADMIN_API_KEY` in the environment.
- `x-admin-key` on JSON calls; timing-safe compare.
- No key configured → `503 ADMIN_NOT_CONFIGURED`.
- The Phase A env-key dashboard remains in the customer API as a break-glass
  surface; the named-admin portal is the separate `admin-web` process documented
  in `docs/ADMIN_WEB_IMPLEMENTATION.md`.
- The portal uses named admins, Argon2id, TOTP, server-side sessions, CSRF,
  origin checks, RBAC and audit. It is the product surface for daily use.
- The env key should be unset in normal production once the portal is deployed,
  except for a documented break-glass path.

This is not sufficient for production:

- one shared secret, no identity;
- no 2FA, no session revocation, no CSRF token;
- no per-action audit actor beyond “env key”;
- `sessionStorage` is vulnerable to XSS.

### Phase B target

- `admin_users` with Argon2id password hashes.
- TOTP 2FA, recovery codes hashed.
- Short-lived admin JWT in an `HttpOnly`, `Secure`, `SameSite=Strict` cookie.
- CSRF token for every state change.
- `admin_sessions` with revocation, last-seen, IP/UA metadata.
- Optional IP allowlist and a separate admin hostname.
- Rate limits per account/IP; lockout after repeated failures.
- CSP, HSTS, no inline scripts in the final SPA (the current shell uses inline
  JS and is explicitly Phase A only).
- Every request gets an `admin_audit_log` row for writes, PII reveals and
  exports.

### Actions that always require a reason

- refunds/manual dispositions;
- payout retries after a terminal failure;
- corridor disable/enable outside an incident;
- LP prefund correction or cancellation with remaining balance;
- any PII reveal or export;
- any ledger adjustment.

### 5.1 Delivery form: what are we building?

**Recommendation: a private, authenticated internal operations portal — not a
public site, not a customer portal, and not an admin mode inside the Flutter
app.**

It should be:

- **desktop-first responsive web app**, usable on a tablet, with a big-screen
  control-room mode;
- **server-rendered first** (Fastify + templates + HTMX + small JS islands +
  SSE), not a heavy SPA in Phase A/B;
- backed by the existing **admin JSON API**, so a React/Vue SPA can replace the
  view layer later without changing the domain;
- deployed on a **separate admin hostname** (`admin.crosspay.example`), behind
  VPN/IP allowlist and 2FA, with no public signup and no search indexing;
- built as a **separate service/container** from the customer API, sharing
  PostgreSQL through a least-privilege role. This keeps admin outages, deploys
  and attack surface away from customer traffic.

Why server-rendered first:

- fewer moving parts and dependencies than an SPA;
- session cookies, CSRF and RBAC are simpler to get right;
- fast on poor connectivity and old laptops;
- easy to audit and to keep the money actions server-authoritative;
- HTMX covers tables, filters, forms and pagination; SSE covers the control
  room; small JS islands cover charts.

When to move to a SPA: if the control room/analytics becomes a genuinely
interactive product with many client-side views, or the team already has strong
React/Vue skills. The API contract stays the same, so this is a view-layer
replacement, not a rewrite.

**Options considered**

| Option | Verdict |
|---|---|
| Internal server-rendered portal (Fastify + HTMX + SSE) | **Recommended for B4.6 Phase A–D** |
| SPA (React/Vue/Svelte + Vite) against the admin API | Good later; more auth/CSRF/tooling surface now |
| Admin mode inside the Flutter app | No: distribution, device loss, poor tables/keyboard, no big-screen |
| Public marketing site + admin | No: wrong threat model, SEO/indexing and attack surface |
| Low-code (Retool/Appsmith) | No for money/ledger; vendor lock-in and weak audit/control |
| Direct database console | Never |

**Suggested stack**

- Backend: existing Fastify/TypeScript API + a separate `admin-web` process.
- Views: Eta or Liquid templates, HTMX, Alpine.js where needed, Tailwind (or
  Pico.css for a zero-build start).
- Real-time: `admin_activity_events` + SSE (`text/event-stream`), polling
  fallback. No WebSocket dependency in Phase C.
- Charts: ECharts or Chart.js, fed by server-computed aggregates/materialized
  views; no raw row scans in the browser.
- Auth: Phase A env key only for break-glass; Phase B named users, Argon2id,
  TOTP, `HttpOnly`/`Secure`/`SameSite=Strict` session, CSRF token, RBAC.
- Hosting: separate subdomain/container, VPN or IP allowlist, WAF, HSTS, CSP,
  `X-Robots-Tag: noindex`, separate deploy pipeline and secrets.
- Observability: Sentry, structured audit logs, uptime checks, synthetic canary
  trades.

**Suggested URL shape**

- `https://admin.crosspay.example/` — portal
- `https://admin.crosspay.example/control-room`
- `https://admin.crosspay.example/analytics`
- `https://admin.crosspay.example/ops/trades/:reference`
- `https://admin.crosspay.example/config/fees`
- `https://admin.crosspay.example/support/cases/:id`

The old `/admin` HTML shell is the **Phase A seed**. The named-admin
`admin-web` portal is now built and should be deployed on the separate admin
hostname; the old shell remains break-glass only and should not grow further.

**Decisions to confirm before Phase B**

1. Separate `admin-web` service/container, or the same Fastify process with a
   separate route group? Recommendation: separate service.
2. Hosting/VPN/IP allowlist and admin hostname.
3. Local admin accounts + TOTP, or company SSO/SAML?
4. HTMX/server-rendered vs a React SPA (recommendation above).
5. Support workspace priority: if customer support is urgent, ship the safe
   support vertical slice before full analytics.

---

## 6. Information architecture

### 6.1 Overview

- Live counts: funded queue, locked matches, pending payouts, pending refunds,
  stuck matches, open incidents.
- Corridor utilization and cap breaches.
- Provider health/outage banner.
- Today's collections, payouts and refunds by currency (separate cards, never
  one mixed total).
- Alerts with age and owning role.

### 6.2 Live ops

**Queue** — every `escrowed`/`matching` trade: reference, corridor, amount,
age, user tier, provider eligibility, deadline. Actions: trigger match, expire
and refund (with reason).

**Matches** — `locked`/`released`/`failed`: match id, organic vs LP, both legs
or LP order, amounts, age, provider references. Actions: resume payout, mark
failed with reason (finance/ops approval).

**Payouts** — pending/submitted/failed/paid: provider, reference, amount,
attempts, last error. Actions: retry (idempotent), open provider statement.

**Refunds** — pending/submitted/failed/paid: provider reference, amount,
reason, reversal journals. Actions: retry, escalate.

**Incidents** — provider outage, corridor breach, stuck match, reconciliation
exception. Acknowledge/resolve with notes.

### 6.2.1 Control room

A wall-friendly and desk-friendly view of the app in real time. It is an
operational radar, not a second ledger.

**Live activity stream**

Every event is an append-only `admin_activity_events` row (or a curated view
over domain events) with a redacted summary:

- OTP requested/verified/failed (phone suffix only);
- session refresh/reuse revoked;
- KYC submitted/approved/rejected;
- quote requested/expired/consumed;
- trade initiated, collection push sent, callback received, claim checked;
- trade escrowed, matched (organic/LP), payout requested, paid, failed;
- refund requested, paid, failed;
- provider outage/recovery, callback signature failure, webhook replay;
- support case opened/updated, customer-safe action performed;
- admin configuration change and admin login.

Each row shows time, event type, severity, corridor, currency, amount (separate
per currency), trade reference, provider, and a masked user marker. Clicking
opens the trade or case; no full PII in the stream.

**Real-time posture**

- Active sessions/users (privacy-preserving counts, not identities);
- trades in each state, per corridor;
- provider health and latency;
- callback lag and failure rate;
- queue depth and oldest age;
- payout backlog and oldest item;
- refund backlog;
- corridor exposure vs cap;
- error budget/SLO burn;
- incident banner.

**Feed controls**

- filters: event type, severity, corridor, provider, status, amount range,
  masked user suffix, trade reference;
- pause/resume, live tail, time-range replay;
- saved views per role;
- “explain this” link from every row to the trade, match, payout or case;
- export a filtered window (permissioned, audited).

**Alerts**

- threshold rules (oldest queue item, callback lag, payout failure rate,
  exposure ≥ 80/100%, signature failures, provider down);
- deduplicate and group by incident;
- acknowledge, assign, link a runbook, resolve with a note;
- page on-call only for critical rules.

**Technical shape**

- Phase C: database-backed event table plus SSE (`text/event-stream`) with
  polling fallback; no WebSocket dependency yet.
- Events are written from the domain service or an outbox worker, not
  reconstructed by polling every table.
- The feed is capped and retention-managed; money/audit tables remain the source
  of truth.
- Big-screen mode hides filters and shows the SLO/queue/exposure tiles only.

### 6.2.2 Analytics

Analytics is a first-class section, not a dashboard afterthought. Every number
links to the records that produced it.

**Business funnel**

- quote requested → quote consumed → collection sent → collection confirmed →
  matched → payout sent → completed;
- drop-off reason at each step (expired quote, provider reject, user cancel,
  timeout, payout failure);
- median/p90 time per step, per corridor and provider.

**Corridors and pricing**

- send/receive volume and count, per currency;
- realized spread and net revenue after provider fees;
- match rate organic vs LP vs direct liquidity;
- queue depth and wait time;
- refund and compensation rate;
- cap utilization and headroom.

**Providers**

- collection/payout success rate, latency, error codes;
- callback lag and signature failures;
- fee per rail/provider;
- outage timeline.

**Liquidity**

- LP prefund, consumed, remaining, utilization, expiry;
- fills per order, average rate vs customer rate;
- failed fills and released capacity;
- concentration per LP.

**Customers and limits**

- KYC funnel and pending queue age;
- daily-limit usage and near-limit users;
- repeat vs new senders (aggregate, no PII);
- support contacts per 1,000 trades.

**Support**

- open/closed cases, first response, resolution time, reopen rate;
- top issue codes and corridors;
- canned-response use;
- CSAT if collected.

**Revenue and bookkeeping**

- fee revenue, spread revenue, provider cost, compensation;
- per currency and corridor;
- refunds and reversals;
- operating cash vs trust cash (from the bookkeeping phase).

**Rules**

- Every tile states its currency, time window and data freshness.
- No mixed-currency total. Use one card per currency or a currency selector.
- Export is a permissioned CSV/JSON job with a token and audit row.
- “Explain” opens the underlying filtered journal/trade list.
- Real-time tiles are clearly labelled; historical charts use closed periods.

### 6.2.3 Configuration and control center

This is where approved operators set how CrossPay behaves. Nothing here is
edited in source code or directly in the database.

**Services and switches**

- payment provider enabled/disabled, sandbox/live mode;
- pricing source and fallback;
- SMS provider and sender ID status (secrets write-only);
- KYC/name-check provider;
- P2P matching global kill switch and per-corridor switches;
- invoice/share availability;
- maintenance banner and app-wide read-only mode.

**Fees and spreads**

- rail-based fee bps: P2P/mobile money 150 bps, bank 250 bps by default;
- min/max fee per currency, rounding rule and fee currency;
- provider fee pass-through policy;
- FX/customer spread bps, corridor overrides and effective dates;
- fee preview against sample amounts before publishing;
- version, approver, effective-from, rollback.

**Tiers and limits**

- daily limit per tier/currency;
- KYC tier requirements;
- per-corridor and per-provider transaction limits;
- risk velocity rules and manual-review thresholds.

**Corridors**

- enable/disable, exposure cap, min/max, deadline, estimate, spread metadata;
- LP depth and active orders;
- change preview: affected queue, exposure and app availability;
- staged rollout by country/hub or percentage (later).

**Providers**

- endpoints and timeouts (not secrets in the browser);
- retry/backoff policy;
- callback URL and secret rotation (write-only, audit);
- allowlists/health thresholds;
- sandbox/live separation.

**App configuration**

- currencies, countries, hubs, payout rails;
- support contacts and hours;
- localized banners and incident messages;
- feature flags for the Flutter app.

**Guardrails**

- schema validation and numeric bounds;
- optimistic concurrency (`version` column);
- two-person approval for fee/spread/limit changes above thresholds;
- effective dates and automatic rollback;
- change diff with before/after and impacted-trade count;
- a “simulate” mode that shows quotes/trades under the proposed policy;
- no silent change: every publish writes audit and an activity event;
- secrets are write-only, encrypted at rest, never returned;
- production changes require a named admin and 2FA.

**Suggested additional controls**

- per-corridor fee overrides with expiry (promo pricing);
- a “freeze new quotes” switch separate from “disable payouts”;
- a “drain” mode that stops new matches but lets existing trades finish;
- provider canary percentage and automatic fallback;
- scheduled maintenance windows and app banner presets;
- config import/export for disaster recovery, signed and audited.

### 6.3 Corridors and policy

Per corridor direction:

- enabled/kill switch;
- exposure cap, open exposure, available, utilization;
- min/max trade amount;
- match deadline;
- spread policy metadata;
- estimated settle seconds shown to the app;
- LP depth and active orders;
- recent matches and failures.

Changes are staged with before/after values and audit. Enabling requires a
non-null cap. Disabling does not cancel existing matches; a separate action is
required and must show the affected trades.

### 6.4 Liquidity providers

- Provider allowlist, status, onboarding reference, contacts (restricted).
- Prefund reference and prefunded amount per currency.
- Standing orders: provide/receive currency, capacity, remaining, min/max,
  rate, expiry, status.
- Utilization and fills; locked matches using an order.
- Actions: create provider, suspend, create order, cancel unused order and
  return remaining prefund, adjust prefund (approval).

The ledger books the prefund on order creation:
`1000-<provide> / 2050-<provide>` (cash / LP payable). Cancelling returns the
unused remaining. A locked match prevents cancellation until it resolves.

### 6.5 Trades and support

Search by reference, trade id, provider reference, phone suffix, date and
status. Default view masks the recipient account and phone; a permissioned
reveal records who, when and why. Show:

- trade object and timeline;
- collection attempts and provider status;
- payout/refund rows and provider references;
- every journal line and account;
- match and LP order;
- support notes (append-only).

No edit of trade amounts, statuses or journal lines. Permitted actions are
“re-check provider”, “resume payout”, “refund” and “add note”, each with its
own permission and audit.

### 6.6 Bookkeeping

This is the replacement for the sandbox `CROSSPAY` mirror.

**Chart of accounts (proposed, Finance/Legal must approve):**

| Code | Account | Type | Purpose |
|---|---|---|---|
| `1000` | Partner trust cash | asset | customer/escrow funds at PSP/bank |
| `1050` | CrossPay operating cash | asset | CrossPay's own money at bank/PSP |
| `2000` | Trade payable | liability | principal owed to recipients |
| `2050` | Liquidity provider payable | liability | LP prefund and settlement position |
| `2100` | Refund payable | liability | refunds in flight |
| `3000` | Fee revenue | revenue | platform fee per trade |
| `3100` | Spread revenue | revenue | P2P match residual |
| `4000`/`5000` | FX position/clearing | asset | direct-liquidity FX bridge |
| `6000` | Provider fees | expense | provider payout fees |
| `6100` | Compensation expense | expense | approved compensation write-off |
| `7000` | Treasury funding | liability | treasury advance for a failed leg |
| `9000` | Suspense | liability | unresolved exceptions only |

**Revenue recognition**

- Fee revenue on collection: net platform fee after provider fee, in the send
  currency.
- Spread revenue on a matched payout: user send amount minus LP/counterparty
  cost, in the send currency.
- No revenue on principal.
- Refund reverses revenue in the same currency.
- Compensation/treasury funding is not revenue.

**Settlement to CrossPay's own account**

When the PSP/bank pays CrossPay's fee in cash:

```
debit  1050 CrossPay operating cash (currency)
credit 1000 Partner trust cash (currency)
```

This is a cash movement, not new revenue. The corresponding provider statement
line and bank/PSP operating account line are required.

**Trial balance and reports**

- Trial balance per currency; never a mixed-currency total.
- Revenue by day/currency/corridor.
- Provider fees and net revenue.
- Refund and compensation ledger.
- LP position by provider and currency.
- Operating cash vs trust cash.
- Journal browser with filters and CSV export (permissioned, audited).

### 6.7 Settlement and reconciliation

Sources:

1. CrossPay ledger journals.
2. Provider statements (collections, payouts, refunds, fees).
3. Bank/PSP operating account statements.

Daily close:

- import/receive statements;
- match each provider reference to one journal and one bank/PSP line;
- classify exceptions: timing, fee mismatch, missing provider line, duplicate,
  currency mismatch, amount mismatch;
- resolve only by posting a documented journal or correcting the import;
- close the day with a signed summary.

No “reconcile” button that silently writes off a difference. Differences go to
`9000 Suspense` only with approval and a named reason.

### 6.8 Support workspace

Support is a first-class user of the admin. The goal is to answer “what happened
to my transfer?” and resolve it safely, without database access or breaking the
money rules.

**Customer lookup**

- search by phone (full number only with a reason; otherwise suffix), email,
  trade reference, provider reference, case id;
- masked profile: display name, country, KYC status/tier, limit currency,
  account status, last active, devices/sessions;
- no raw KYC identifier, no full recipient account, no card data.

**Customer 360**

- active and recent trades with status, amount (per currency), age and next
  action;
- quote history and why a quote expired;
- beneficiaries (masked) and rail availability;
- collection attempts, provider status, callback history, last error;
- payout/refund rows and provider references;
- daily-limit usage;
- recent notifications/SMS delivery status;
- support cases and notes;
- account/session security events (sign-in, refresh reuse, OTP failures).

**Explain the state**

For any trade, the workspace shows a plain-language “why”:

- waiting for the payer's phone approval;
- provider push timed out; manual fallback available;
- provider rejected the wallet with code X;
- collection confirmed; waiting for a match;
- matched with an LP/user; payout submitted; provider ETA;
- payout failed; refund in progress or refunded;
- corridor disabled / provider down.

Each explanation links to the underlying event, provider reference and journal.

**Customer-safe actions**

| Action | Permission | Guardrail |
|---|---|---|
| Re-check collection/payout status | ops/support | idempotent; never marks paid |
| Resend receipt / instructions | support | rate-limited, logged |
| Cancel a pending trade | support | only `pending_deposit`; server decides |
| Trigger a match attempt | ops | only funded trade; result is server truth |
| Retry a pending payout/refund | ops | idempotent; no new provider reference |
| Reset a customer session | support | revokes refresh family; audited |
| Add case note / tag / assign | support | append-only |
| Send a templated message | support | approved templates, logged |
| Reveal masked PII | compliance | reason + audit; time-boxed |
| Refund | finance/ops | approval threshold; provider-confirmed |
| Mark paid / edit ledger / bypass KYC | **nobody** | not an admin action |

**Case workflow**

- open from a trade, user or inbound message;
- priority, queue, assignee, SLA timer;
- tags and issue codes (provider down, wrong number, limit, KYC, duplicate,
  refund, other);
- canned responses localized to the customer's language;
- internal notes and customer-visible replies separated;
- escalation to ops/finance/compliance with the trade attached;
- reopen tracking and CSAT.

**Support metrics**

- contacts per 1,000 trades;
- top issue codes/corridors;
- first response, resolution time, reopen rate;
- cases waiting on provider vs customer vs CrossPay;
- agents online and backlog.

**Privacy and safety**

- list views are masked by default;
- a PII reveal requires a reason, expires, and is audited;
- support cannot see another customer's data through a crafted reference;
- copy/export is disabled for sensitive fields unless permissioned;
- every support action appears in the control-room activity feed.

### 6.9 Compliance

- KYC verification queue and manual review.
- Name-check mismatch review; no raw registered-name exposure.
- Sanctions hit queue; block/release with approval.
- PII reveal and export audit.
- Regulatory hold / account freeze with a reason and dual approval.

---

## 7. Data model additions

### Admin identity

```sql
admin_users (id, email, password_hash, totp_secret_encrypted, status,
             created_at, updated_at, last_login_at)
admin_sessions (id, admin_user_id, token_hash, csrf_hash, ip, user_agent,
                created_at, last_seen_at, revoked_at, expires_at)
admin_user_roles (admin_user_id, role, granted_by, granted_at)
admin_audit_log (id, admin_user_id, action, resource_type, resource_id,
                 reason, before, after, ip, user_agent, created_at)
admin_approvals (id, action, resource_type, resource_id, requested_by,
                 approved_by, status, reason, created_at, decided_at)
```

### Control room and configuration

```sql
admin_activity_events (id, event_type, severity, source, trade_id, match_id,
                       payout_id, refund_id, support_case_id, provider,
                       currency, amount_minor, summary, payload, created_at)
config_versions (id, config_key, version, value, effective_from, effective_to,
                 status, proposed_by, approved_by, created_at, published_at)
fee_policies (id, rail, currency, fee_bps, min_fee_minor, max_fee_minor,
              rounding, version, effective_from, effective_to, status,
              approved_by)
provider_settings (id, provider, kind, enabled, mode, timeout_ms, retry_policy,
                   callback_url, secret_ref, version, approved_by, updated_at)
feature_flags (key, value, scope, enabled, version, effective_from,
               updated_by, updated_at)
app_banners (id, locale, severity, message, starts_at, ends_at, enabled)
```

### Support

```sql
support_cases (id, trade_id, user_id, opened_by, assignee, status, priority,
               issue_code, summary, sla_due_at, created_at, updated_at)
support_notes (id, case_id, author_admin_id, visibility, note, created_at)
support_messages (id, case_id, channel, template_code, locale, status,
                  sent_at, sent_by)
```

### Reconciliation

```sql
settlement_statements (id, source, provider, currency, period_start, period_end,
                       file_hash, imported_by, imported_at, status)
settlement_lines (id, statement_id, provider_reference, kind, amount_minor,
                  currency, occurred_at, matched_journal_id, matched_bank_line_id,
                  status)
reconciliation_runs (id, business_date, currency, status, summary, closed_by,
                     closed_at)
reconciliation_exceptions (id, run_id, kind, reference, amount_minor, currency,
                           status, note, resolved_by, resolved_at)
```

All admin tables are separate from customer tables and never expose passwords,
TOTP secrets, full PII or provider credentials in list responses.

---

## 8. Admin API surface

All JSON under `/api/v1/admin`, authenticated by admin session/key and role.

### Read

- `GET /overview`
- `GET /control-room/stream` (SSE), `GET /control-room/snapshot`
- `GET /control-room/activity?type=&severity=&from=&to=`
- `GET /analytics/funnel`, `/analytics/corridors`, `/analytics/providers`,
  `/analytics/liquidity`, `/analytics/support`, `/analytics/revenue`
- `GET /corridors`, `GET /corridors/:send/:receive`
- `GET /queue`
- `GET /matches`, `GET /matches/:id`
- `GET /payouts`, `GET /refunds`
- `GET /liquidity/providers`, `GET /liquidity/orders`
- `GET /trades?reference=&status=&from=&to=`
- `GET /trades/:id`, `/timeline`, `/journals`
- `GET /support/cases`, `/support/cases/:id`
- `GET /config/services`, `/config/fees`, `/config/tiers`, `/config/providers`,
  `/config/feature-flags`
- `GET /bookkeeping/trial-balance?currency=`
- `GET /bookkeeping/journals?currency=&from=&to=&account=`
- `GET /bookkeeping/revenue?currency=&from=&to=`
- `GET /reconciliation/runs`, `/exceptions`
- `GET /audit`

### Writes (Phase A only, all audited)

- `PATCH /corridors/:send/:receive` — enable/disable, cap, min/max, deadline,
  estimate.
- `PATCH /config/fees/:id`, `POST /config/fees` — versioned fee policy.
- `PATCH /config/services`, `PATCH /config/feature-flags`,
  `PATCH /config/providers/:provider` — versioned service/provider settings.
- `PATCH /config/tiers/:tier/:currency` — daily limits (finance approval).
- `POST /control-room/events/:id/ack` — acknowledge an alert.
- `POST /support/cases`, `PATCH /support/cases/:id`,
  `POST /support/cases/:id/notes`, `POST /support/cases/:id/messages`.
- `POST /support/trades/:id/recheck`, `/cancel`, `/retry-payout`,
  `/retry-refund`, `/reset-session` — customer-safe actions.
- `POST /trades/:id/match` — one FIFO attempt.
- `POST /matches/:id/disburse` — resume both legs.
- `POST /liquidity/providers`, `PATCH /liquidity/providers/:id`.
- `POST /liquidity/orders` (requires prefund reference and books the prefund).
- `PATCH /liquidity/orders/:id` — cancel unused order and return remaining.
- `POST /payouts/:id/retry` (later)
- `POST /refunds/:id/retry` (later)
- `POST /trades/:id/refund` (later; approval)
- `POST /approvals/:id/approve|reject` (later)

Every write is idempotent, has a reason field, checks role, and writes an audit
row. Money writes also write the domain journal/transition in the same database
transaction where possible.

---

## 9. UI structure

Phase A is a single server-served page with no build step:

- key prompt;
- overview cards;
- corridors table with enable/disable;
- funded queue;
- open matches;
- pending payouts/refunds;
- LP orders;
- alerts.

Phase B replaces it with a small authenticated SPA or server-rendered pages:

```
Overview
Control room ─ Live feed / Alerts / SLOs / Big-screen
Analytics   ─ Funnel / Corridors / Providers / Liquidity / Support / Revenue
Live ops    ─ Queue / Matches / Payouts / Refunds / Incidents
Policy      ─ Corridors / Liquidity providers / Orders
Config      ─ Services / Fees & spreads / Tiers & limits / Providers / Flags / Banners
Trades      ─ Search / Trade detail / Support notes
Support     ─ Cases / Customer 360 / Safe actions / Canned replies
Finance     ─ Trial balance / Journals / Revenue / Costs / Operating cash
Recon       ─ Statements / Runs / Exceptions
Compliance  ─ KYC / Name checks / Sanctions / PII reveal
Audit       ─ Admin actions / PII reveals / Exports
Settings    ─ Admin users / Roles / Thresholds / Feature flags
```

Design rules:

- currency is always visible next to an amount;
- separate cards/rows per currency;
- destructive actions show the exact trade/match/LP reference and amount;
- no action without a reason where required;
- optimistic UI is not allowed for money; wait for the server;
- 409/503 states show the provider code and a retry path.

---

## 10. Bookkeeping and sandbox cutover

The sandbox currently records a testing-only mirror of CrossPay revenue. It is
not the admin book and must be removed.

Cutover checklist:

1. Finance approves the chart of accounts and revenue recognition.
2. CrossPay ledger records fee/spread/refund/compensation with the final
   account codes.
3. Admin journal browser and per-currency trial balance are live.
4. A real provider statement and bank/PSP operating-account line reconcile to
   the CrossPay ledger for one complete day.
5. Operating-cash transfer from trust to operating account is journaled.
6. Sandbox `CROSSPAY` mirror is disabled and its docs/tests updated.
7. No reporting job depends on the sandbox.

---

## 11. Acceptance tests

- RBAC matrix: every role, every write, allow/deny.
- Missing key/session → 401; unconfigured admin → 503.
- 2FA required for privileged roles; replay/expired TOTP rejected.
- CSRF token required on every state change.
- Session revoke takes effect immediately.
- Corridor enable without a cap → 422.
- Disabling a corridor does not cancel live matches; affected list is shown.
- LP order creation without a prefund reference → 422; prefund journal balances.
- Cancelling an order with a locked match → 409.
- LP payout success consumes capacity and posts one send + one receive journal.
- LP payout failure refunds the trade and returns capacity exactly once.
- Match/payout/refund retries are idempotent.
- Ledger tables reject admin UPDATE/DELETE.
- Trial balance per currency sums to zero; no mixed-currency total exists.
- Settlement close refuses an unresolved exception.
- PII reveal requires permission, reason and writes audit.
- Audit log is append-only and includes before/after values.
- Admin CSV exports are tokenized, expiring and audited.
- Control-room stream is redacted, resumes after reconnect and never exposes
  full PII.
- Analytics every tile states currency/window/freshness; no mixed-currency
  total; “explain” opens the underlying records.
- Fee/spread/limit changes are versioned, validated, approved where required,
  effective-dated and reversible; a quote before the effective time is
  unaffected.
- A service kill switch stops new work without corrupting in-flight trades.
- Support customer-safe actions never mark a trade paid or edit a journal; a
  re-check is idempotent and returns provider truth.
- Support PII reveal requires permission/reason and writes audit.
- Support case notes are append-only and visible in the control room.
- Admin activity events are written for every money and configuration action.

---

## 12. Open decisions

1. Admin hosting: same API host with a separate path, or an isolated admin
   hostname/VPC? Recommendation: isolated subdomain with IP allowlist.
2. Identity: local admin accounts + TOTP, or SSO/SAML if the company already
   has an IdP? Recommendation: local + TOTP for v1, SSO later.
3. Approval thresholds: refund/payout/LP correction amounts per currency.
4. Statement ingestion: manual CSV upload, provider API, or bank feed first.
5. Business-day/timezone and cutoff rules per corridor.
6. Data retention for audit, PII reveals, support notes and reconciliation.
7. Who owns incident acknowledgement and whether it pages on-call.
8. Whether finance can post a manual journal directly or only propose one.
9. The final operating-cash account structure per bank/PSP.
10. When the sandbox mirror can be removed: after C and D pass, not before.

---

## 12.1 Suggestions for the control room and support

**High value, low risk**

1. **Event outbox + SSE.** Write a small `admin_activity_events` row from the
   domain services and stream it. This is simpler and cheaper than polling every
   table or introducing Kafka.
2. **“Explain this number” everywhere.** Every metric, alert and status should
   open the filtered trades/journals that produced it. This is the single best
   support feature.
3. **Read-only impersonation.** “View as customer” shows their screens and data
   without issuing a customer token. Completely audited.
4. **Runbooks attached to alerts.** Each alert type links to “what to check,
   what to say, what not to do”.
5. **Masked-by-default search.** Phone suffix and trade reference are enough for
   most support calls; full PII is a separate permissioned action.
6. **Canned replies in the customer's language.** Keep them short and factual.
7. **Support-safe actions only.** Re-check, resend, cancel pending, reset
   session, add note, escalate. No “mark paid”.
8. **Alert deduplication.** One incident per provider/corridor, not one alert
   per trade.
9. **Big-screen mode.** Queue, exposure, provider health, payout backlog, SLO
   burn. No PII.
10. **Saved views** per role: “My open cases”, “Payouts stuck > 5m”, “KES
    corridor > 80%”.

**Later, high leverage**

11. **Shadow mode for fee/spread changes.** Run the proposed policy on live
    quote inputs without publishing; compare revenue and customer impact.
12. **Canary provider routing.** Send a small percentage to a new provider and
    auto-fallback on errors.
13. **Anomaly detection.** Sudden payout failure, signature failures, OTP
    failure spikes, one user creating many quotes, corridor exposure velocity.
14. **Synthetic canary trades** in the sandbox on a schedule, with a control-room
    tile and alert if the canary fails.
15. **Support CSAT and reopen tracking** tied to issue codes.
16. **Knowledge base** linked from issue codes and canned replies.
17. **Config import/export** for disaster recovery, signed and audited.
18. **Per-hub/country feature flags** for staged rollout.
19. **Drain mode** that stops new matches but lets existing trades finish.
20. **Post-incident timeline** assembled from the activity feed, alerts and
    admin actions.

**Do not build**

- a direct SQL console;
- a “mark as paid” button;
- a ledger edit screen;
- a PII bulk export;
- a shared admin password;
- a control room that shows full phone numbers by default;
- a fee editor without versioning/approval;
- an analytics total that mixes currencies.

---

## 13. B4.6 built so far

**Phase A, local-account Phase B, the Phase C feed/analytics, read-only
bookkeeping, Phase D configuration v1, Phase F reconciliation v1 and the Phase G
manual support workspace are built:**

- separate `admin-web` process with server-rendered pages;
- named `admin_users`, Argon2id passwords, TOTP, encrypted secrets, recovery
  codes, replay guard, login rate limit;
- server-side sessions, HttpOnly/SameSite cookies, CSRF, origin checks, security
  headers, session revocation;
- roles `viewer`, `ops`, `finance`, `compliance`, `superadmin`;
- overview, live SSE control room with snapshot fallback, windowed analytics
  (`24h`/`7d`/`30d`/`all`), funnel, fee/spread revenue, provider performance,
  corridors, liquidity providers/orders, trade search/detail, audit,
  admin-user management;
- read-only bookkeeping: debit-positive trial balance per currency, journal
  browser/detail, reversal and FX-partner links, `ledger:read` permission;
- manual support workspace: `CS-…` cases from a customer/trade, append-only
  notes, priority/status/assignee, canned replies, customer 360, masked PII,
  permissioned/reasoned PII reveal and optional provider-gated SMS replies;
- configuration v1: versioned support-contact and tier-limit proposals,
  two-person approval, config versions, rollback proposals, emergency
  quote/trade pauses enforced by the API, and provider-observed fee bps shown
  read-only;
- reconciliation v1: append-only manual provider/bank statement import,
  exact reference/amount/currency or posting-key matching, provider
  missing-in-statement detection, typed exceptions, required resolution notes,
  blocked close while exceptions are open, and a final per-statement daily
  close;
- trigger-fed append-only `admin_activity_events` outbox and
  `pg_notify('admin_activity')`, so every process feeds the control room;
- ops actions: re-check, match, disburse/resume, payout retry, refund, refund
  retry;
- append-only `admin_audit_log` with the acting admin id;
- CLI bootstrap (`npm run admin:create`) with terminal QR and recovery codes;
- tests for auth, replay, CSRF, RBAC, pages, stream delivery, analytics,
  bookkeeping, support masking/append-only notes/PII audit/SMS gating,
  configuration approval/enforcement, TOTP enrolment, last-superadmin guard
  and audit.

**Not built yet:**

- SSO; local accounts + TOTP only.
- Recovery-code login flow.
- `LISTEN/NOTIFY` transport (polling + SSE is live); analytics charts, saved
  views and scheduled exports.
- Configuration remainder: provider secrets/endpoints, feature flags, app
  banners, effective-date scheduling, per-corridor fee overrides and a fee
  editor pending provider reconciliation.
- Reconciliation remainder: live provider/bank feeds, file upload, automatic
  bank-side missing-in-statement detection, fee-line matching, correction/re-open
  and bank balance matching.
- KYC/sanctions compliance queues, approvals beyond configuration, SPA, IP
  allowlist deployment. Support has no customer-facing chat, email or WhatsApp
  channel yet.

See `docs/ADMIN_WEB_IMPLEMENTATION.md` for setup and current limitations.

---

## 14. What “done” means for the admin

The admin is done when:

- a named operator, not a shared key, can do every action;
- every action is authorized, reasoned, idempotent and audited;
- finance can explain every penny from a trade to a provider statement to a
  bank/PSP operating-account line;
- no screen mixes currencies;
- no admin can edit or delete ledger history;
- the sandbox testing mirror is gone;
- an incident can be seen, acknowledged and resolved without database access.
