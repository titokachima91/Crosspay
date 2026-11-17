# CROSSPAY: MASTER PROGRESS REPORT

**Updated**: 2026-11-16
**Project**: CrossPay
**Package**: crosspay_app
**Environment**: macOS Monterey | Flutter 3.24.5 | Dart 3.5.4 | Node 24 | PostgreSQL 17 for the API | SQLite for the sandbox
**Progress**: Frontend complete except F5.3 partial · B1 complete · B2.0, B2.2, B2.3, B2.4 and B4 (matching, LP liquidity, exposure, app matching states, Phase A/B ops admin portal) complete · market depth, analytics, CSV export and the reconciliation worker complete · sandbox reference implementation complete · live collection, payout, signed-callback and two-leg P2P flow verified · B4.6 control room/analytics/config/bookkeeping and B3 invoice/share remain

---

## PROJECT OVERVIEW

CrossPay is engineered as a non-custodial, server-driven cross-border payments
engine. The app only displays state; it never holds customer funds. Escrow
deposits flow to licensed partner bank/PSP omnibus trust accounts.

CrossPay now has four working parts:

1. **Flutter app** — the finished UI, wired to real repositories.
2. **CrossPay API** — Fastify + PostgreSQL, with B1 data, B2.0 bootstrap,
   B2.2 pricing/quotes, B2.3 collections and B2.4 payouts/refunds/webhooks.
3. **Kachi sandbox** — a provider-side reference implementation with a bank,
   PSP, KYC, institutions, ledger and a `/api/v1` CrossPay facade.
4. **Live contract tests** — the real Flutter repositories and the CrossPay
   pricing adapter are tested against the running sandbox.

### Live project locations

| What | Live location | Desktop copies |
|---|---|---|
| Flutter app + `server/` API | `/Users/apple/development/crosspay_app` | timestamped snapshots, backup only |
| Kachi fintech sandbox | `/Users/apple/.cline/data/workspaces/chat/kachi-fintech-sandbox` | timestamped snapshots, backup only |

Desktop folders are not the live tree. Editing or running one does not change
the live app, the API or the live SQLite database.

**Real app**: `flutter run -d chrome --dart-define=API_BASE_URL=<address>`

**Preview**: `flutter run -d chrome -t preview/main.dart` — simulated data,
code 1234

---

## CORE PRINCIPLES

1. No wallet, no stored balance — receive = payout to mobile money/bank.
2. No mocks, nothing hardcoded in `lib/` — data and rules come from the server.
3. Simulated data lives ONLY in `preview/`.
4. Money = whole numbers in the smallest unit (`Currency.decimals` from server).
5. Server calculates, app displays.
6. Unconnected pieces say so plainly ("unavailable", "not connected").
7. Screens verified by widget tests and walkable in the preview app.
8. Identity data (ID/TIN) never stored, kept in state or logged on device.
9. Safeguard claims shown only when the server confirms them.
10. Recipient checks never reveal the registered name; one idempotency key per
    attempt.
11. Only the server decides that a payment arrived; the app only reads status.
12. Every money movement posts through a double-entry ledger; balances are
    derived, never stored as mutable wallets.

---

## PART 1: FRONTEND (FLUTTER / RIVERPOD)

### F1 Core
- [x] F1.1 Scaffold and directory tree
- [x] F1.2 Theme (light/dark/system, remembered, WCAG-checked)
- [x] F1.3 Localization engine (en | sw, parity checked)
- [x] F1.4 Riverpod state (auth, quote, trade, rates, config)
- [x] F1.5 Network client (Dio, JWT, retry, idempotency interceptor)

### F2 Auth and onboarding
- [x] F2.1 Splash and language switcher
- [x] F2.2 Phone entry and carrier suggestion
- [x] F2.3 SMS OTP verification grid and secure token storage
- [x] F2.4 Identity and KYC (personal and business)
- [x] P1 Preview app (extra)

### F3 Transaction engine
- [x] F3.1 Home dashboard and converter, four-tab navigation
- [x] F3.2 Route selection and rate lock (fee on top)
- [x] F3.3 Recipient details and name check
- [x] F3.4 Payment prompt and manual fallback
- [x] F3.5 Live escrow and queue tracker, support screen
- [x] F3.6 Digital invoice and share sheet

### F4 Ledger and market
- [x] F4.1 Searchable ledger, status timeline, CSV export, analytics
- [x] F4.2 Market depth and queue health

### F5 Profile and security
- [x] F5.1 Profile and limit bar
- [x] F5.2 Saved recipients CRUD
- [ ] F5.3 Security — **partial**: PIN lock, app-shell gate, language and theme
  persistence shipped; biometrics not wired; app-side refresh-token handling
  not implemented (the server endpoint exists)

**Frontend verification**:
- `dart analyze lib test preview` → **No issues found** (2026-11-15)
- `flutter test` → **219 passed, 1 skipped** (2026-11-15); the skipped test is
  the opt-in live sandbox contract test
- The last full static/build check remains: `flutter build web --release -t
  preview/main.dart` → **Built build/web** (2026-11-10)

---

## PART 2: BACKEND (NODE.JS + TYPESCRIPT + POSTGRESQL)

Code: `server/` inside the CrossPay repository.

### B1 Database foundation (plan: `docs/B1_DATABASE_PLAN.md`)
- [x] B1.0 Conventions and contract reconciliation
- [x] B1.1 Identity, access and reference data
- [x] B1.2 Recipients
- [x] B1.3 Quotes, quote routes and trades
- [x] B1.4 Idempotency and concurrency
- [x] B1.5 Double-entry ledger (structure verified; chart provisional)
- [x] B1.6 Financial operations scaffolding
- [x] B1.7 Migrations, seed, ERD and verification

**Status**: built and tested 2026-11-14 → `docs/B1_IMPLEMENTATION.md`.
Seven migrations, 48 provisional ledger accounts, double-entry journal,
idempotency and quote lifecycle. Finance/Legal sign-off of the chart of
accounts and escrow treatment remains the only open B1 gate.

### B2 API
- [x] B2.0 Bootstrap: `/config`, OTP, refresh rotation, `/me`, KYC, recipients
- [x] B2.1 Idempotency: database primitive plus HTTP wrapper on every write
- [x] B2.2 `/rates`, `/trade/estimate`, `/trade/quote`
- [x] B2.3 `/trade/initiate` plus trades list/detail/history/claim/cancel
- [x] B2.4 `/trades/:id/disburse`, `/trades/:id/refund`, signed provider webhooks

**B2.0 status**: built and tested 2026-11-15 → `docs/B2_IMPLEMENTATION.md`.
JWT access tokens, rotating refresh tokens, database-backed rate limits,
encrypted KYC and recipient storage, honest `503` states before providers were
connected.

**B2.2 status**: built and tested 2026-11-15 →
`docs/B2_2_IMPLEMENTATION.md`.

| Endpoint | Behaviour |
|---|---|
| `GET /api/v1/rates` | provider rates with the contract shape |
| `GET /api/v1/trade/estimate` | signed-in indicative estimate, no lock |
| `POST /api/v1/trade/quote` | KYC and limit checks, durable quote + route snapshot |

- New `PricingProvider` boundary:
  - `DisabledPricingProvider` — default, honest `503 PRICING_NOT_CONFIGURED`
  - `SandboxPricingProvider` — the reference provider in
    `kachi-fintech-sandbox`
- Provider responses are Zod-validated; outages and malformed data become
  `503 PRICING_UNAVAILABLE`.
- Quotes store rate, fee, payout, total debit, estimates, recommendation,
  status, safeguards and fee breakdown in `quotes` + `quote_routes`.
- Quote creation validates fee math, route uniqueness, one recommendation and
  the lock window before writing.

**B2.3 status**: built and tested 2026-11-16 →
`docs/B2_3_B2_4_IMPLEMENTATION.md`.

| Endpoint | Behaviour |
|---|---|
| `POST /api/v1/trade/initiate` | consume quote, re-check limits, snapshot recipient, start one collection |
| `GET /api/v1/trades` | the signed-in user's trades, newest first |
| `GET /api/v1/trades/:id` | one trade; polling target for the app |
| `GET /api/v1/trades/:id/history` | immutable status timeline |
| `POST /api/v1/trades/:id/payment-claim` | re-check the provider; never marks paid by itself |
| `POST /api/v1/trades/:id/cancel` | cancel a pending deposit; refuses after `ALREADY_PAID` |

- Collection posting is two single-currency journals: partner trust cash /
  trade payable for principal, partner trust cash / fee revenue for the **net**
  platform fee after the provider fee.
- The trade reference is deterministic and is also the provider idempotency
  key, so a retry after a rolled-back transaction cannot double-charge.
- A late provider success after cancel is booked and refunded, never ignored.
- Live smoke: real sandbox quote → STK push → simulated PIN → claim →
  `escrowed`, journals balanced.

**B2.4 status**: built and tested 2026-11-16 →
`docs/B2_3_B2_4_IMPLEMENTATION.md`.

| Endpoint | Behaviour |
|---|---|
| `POST /api/v1/trades/:id/disburse` | start/resume a payout; `202` pending, `200` terminal |
| `POST /api/v1/trades/:id/refund` | full refund of a confirmed collection, provider-confirmed first |
| `POST /api/v1/webhooks/payments/:provider` | public, HMAC-signed collection/payout callbacks |

- Payout success posts **two linked single-currency FX journals** plus the
  payout journal. `fx_group_id` links them; minor units are never summed
  across currencies.
- A payout rejection or failure refunds the payer and reverses both collection
  journals.
- Webhooks verify the raw body, a bounded timestamp and an HMAC, then use
  `(provider, provider_event_id)` for replay protection.
- Live smoke: TZS collection → sandbox FX liquidity → KES mobile-money payout →
  signed callback → `completed`.

**B4 status**: matching v1 built and tested 2026-11-16 →
`docs/B4_MATCHING_IMPLEMENTATION.md`.

- Only funded `escrowed` mobile-money trades enter the queue; matching is
  `P2P_ENABLED=true` plus an enabled `p2p_corridors` row with an exposure cap.
  Nothing is enabled by default.
- FIFO full-fill: oldest opposite trade, deterministic trade-id tie-break,
  both rows locked in one transaction.
- Match ledger is single-currency: `p2p_settlement` releases the counterpart's
  principal and creates the payout payable; spread goes to `3100` spread
  revenue. No FX journal for a matched pair.
- Two-leg saga: a first-leg failure refunds both legs; a second-leg failure
  refunds the second leg and books a `p2p_compensation` treasury advance.
- Match deadline expiry refunds the trade. A reconciliation worker sweeps
  deadlines, resumes locked matches and pending payouts, and retries refunds.
- Live smoke: two real sandbox collections in opposite directions matched, both
  payouts completed, match `released`, every journal balanced.
- `GET /market/depth` now reports real funded-queue depth for enabled corridors
  with an approved `estimated_settle_seconds`; no corridor estimate is invented.
- `GET /trades/analytics` and `GET /trades/export` are live; the CSV link is a
  five-minute token for that user, and export is an honest `503` without
  `PUBLIC_API_URL`.

### B3 Payments
- [x] B3.1 Inbound webhook (delivered in B2.4)
- [x] B3.2 P2P queue sweep (delivered in the reconciliation worker)
- [x] B3.3 Refund retry worker (delivered in the reconciliation worker)

### B4 P2P matching engine (v1 built)
- [x] B4.1 Funded-trade queue and eligibility
- [x] B4.2 FIFO full-fill matcher with row locks
- [x] B4.3 Two-leg payout saga and compensation
- [x] B4.4 Corridor exposure and liquidity providers
- [x] B4.5 App matching states
- [x] B4.6 CrossPay ops admin / control room (Phase A + local-account Phase B)

**B4.4**: per-corridor exposure view, min/max bounds, allowlisted pre-funded
liquidity providers with standing orders, prefund/return journals, LP matching
and exact capacity release on failure. **B4.6 Phase A/B**: separate `admin-web`
portal, named admins, Argon2id, TOTP, server-side sessions, CSRF, RBAC, org
pages, audit and safe ops actions. Control room SSE, analytics charts,
configuration center, bookkeeping and reconciliation are planned in
`docs/ADMIN_PANEL_PLAN.md`; current portal details in
`docs/ADMIN_WEB_IMPLEMENTATION.md`.

**Built**: `docs/B4_MATCHING_IMPLEMENTATION.md`. Matching is off by
`P2P_ENABLED=false` and per-corridor rows in `p2p_corridors`; no corridor is
seeded. The engine lives in CrossPay, not in the sandbox.

---

## PART 3: KACHI SANDBOX — PROVIDER REFERENCE IMPLEMENTATION

The sandbox is not a second CrossPay API. It is the provider side: bank, PSP,
KYC, sanctions, institutions, ledger, callbacks and a full `/api/v1` facade the
Flutter app can use directly.

### What is built

- **Persistence**: SQLite (WAL, foreign keys), schema v2, append-only
  double-entry ledger, derived balances, unique posting keys, reversals.
- **Institution factory**: 19 countries, 19 currencies, 37 seeded banks, PSPs
  and KYC partners, all dynamic; unlimited additional institutions with
  country, currency and services.
- **Provider customers**: PSP wallets, bank customers and KYC identity records
  under any institution; ledger balances, cash-in/out, freeze, statements and
  a dashboard Customers panel. Collections debit the payer wallet; payouts and
  refunds credit the recipient/payer wallet.
- **Accounts and clearing**: customer accounts belong to the provider, not
  CrossPay. CrossPay partner accounts at any bank with a shared cross-border
  balance sheet are settlement/clearing/trust accounts with zero opening
  balances; Stanbic TZ/KE are seeded examples. The dashboard shows owner, type
  and purpose, and can create partner accounts under any bank. CrossPay never
  holds customer cash or a customer wallet.
- **CrossPay revenue book (testing-only in the sandbox)**: the sandbox keeps a
  clearly labelled `CROSSPAY` mirror book for fee revenue, FX spread, provider
  receivable, trust asset, beneficiary payable and operating cash. It exists so
  sandbox tests can prove every penny of the revenue path. It is **not**
  CrossPay's home: real income is money in CrossPay's bank/PSP operating
  accounts and is recorded in the CrossPay admin bookkeeping section. See
  `docs/REVENUE_AND_BOOKKEEPING.md`. Fees are recognised on collection, settled
  into the operating bank account, and reversed on refund; customer and trust
  funds are never mixed in.
- **Bank**: accounts, statements, FX, settlement, clearing queue, approval,
  reversal, cancellation, deposit/withdraw, same-currency `transfer`, EOD,
  liquidity, reconciliation, alerts and audit.
- **PSP**: collections, payouts, partial/full refunds, provider routing,
  status/simulate endpoints, signed callbacks.
- **KYC**: NIN, TIN, name match without revealing the name, sanctions, sessions,
  documents, duplicate detection; raw IDs never stored.
- **Resilience**: provider health, deterministic outage injection, incidents,
  webhook replay and ledger verification.
- **Dashboard**: fintech panels plus a **CrossPay Facade** panel with live OTP
  codes, users, quotes, trades and Collect/Payout controls.
- **CrossPay facade** (`/api/v1`):
  - config, rates, OTP/JWT/refresh, refresh rotation and family revocation
  - `/me`, KYC, limits, beneficiaries and recipient checks
  - estimate, locked quote, initiate, collection, payout, completion
  - cancel, payment claim, expiry, failed collection and refund paths
  - trade list/history, invoice, share link, QR, payer page and one-time CSV
  - analytics, market depth and a sandbox operator surface
  - userless provider pricing for the CrossPay API
  - idempotency with 5xx release so provider outages can be retried
- **Payer page**: `/pay/:token` and `/pay/:token/qr.png`; dev payer action can be
  disabled with `FACADE_DEV_PAY=false`.
- **Sandbox OTP visibility**: codes are returned as `sandboxCode` and shown on
  the dashboard; `FACADE_DEV_OTP=false` hides them and a six-digit value fixes
  the code.

### Sandbox verification

- `npm test` → **37/37** (14 facade + 9 simulator + 10 provider customers +
  4 real-SMS), temporary SQLite.
- Live end-to-end smoke: config → OTP → KYC → beneficiary → quote → initiate →
  collect → payout → completed → invoice/QR/payer page → export → analytics →
  market depth → dashboard state.
- Failure paths: failed collection, failed payout with refund/ledger unwind,
  provider outage with idempotent retry, refresh-token reuse.
- Provider wallet flow: collection debited the payer wallet by 101,500 TZS,
  payout credited the recipient wallet, refund credited the payer wallet.
- Revenue flow: net fee 485 TZS became a CrossPay receivable, settled to
  operating cash and mirrored to `CPA-OPERATING-STANBIC-TZ-TZS`.
- The real Flutter repositories pass an opt-in live contract test:
  `LIVE_SANDBOX=1 ... flutter test test/live_sandbox_test.dart`.

---

## END-TO-END FLOW (CURRENT)

The complete quote → trade → collection → payout → invoice flow currently runs
through the sandbox facade and the real Flutter repositories. This is the
working demo path.

```
Flutter app
  │  /api/v1 (JWT, Idempotency-Key, nested errors)
  ▼
Kachi sandbox facade
  │
  ├── bank / PSP / KYC / institutions / ledger services
  └── SQLite
```

The CrossPay API now prices the same corridors against the sandbox reference
provider:

```
CrossPay API  ──GET /api/v1/rates, /sandbox/pricing/*──▶  Kachi sandbox
     │
     └── PostgreSQL: quotes + quote_routes
```

The CrossPay API does not initiate or pay yet; that is B2.3/B2.4.

---

## TEST AND VERIFICATION SUMMARY

| Suite | Result | Date |
|---|---|---|
| Flutter widget/unit | **219 passed, 1 skipped** | 2026-11-15 |
| Flutter static analysis | **No issues found** | 2026-11-15 |
| Live Flutter contract against sandbox | **passed** | 2026-11-15 |
| CrossPay API `typecheck` | **clean** | 2026-11-15 |
| CrossPay API `build` | **clean** | 2026-11-15 |
| CrossPay API tests | **53/53, 12 suites** | 2026-11-15 |
| Sandbox tests | **37/37** (14 facade + 9 simulator + 10 customers + 4 real-SMS) | 2026-11-15 |
| B2.0 snapshot restore | `npm ci` + typecheck + build + **36/36** | 2026-11-15 |
| B2.2 snapshot restore | `npm ci` + typecheck + build + **42/42** | 2026-11-15 |
| Sandbox snapshot restore | `npm ci` + **37/37** | 2026-11-15 |
| Ledger integrity | `PRAGMA integrity_check` → **ok**, schema v3 | 2026-11-15 |

Live provider check through the real `SandboxPricingProvider`:
KES→TZS `0.057143`, fee 150 bps, payout 17,500 TZS minor, total debit 101,500
KES minor for a 100,000 KES minor send; p2p and bank available; five-minute
lock.

---

## BACKUPS AND RECOVERY

Desktop copies are timestamped, verified snapshots. They are never overwritten
and never used as the live tree.

**Latest CrossPay snapshot**
`~/Desktop/crosspay_app_2026-11-15_073154_b2.2-pricing`
Commit `5e00d9e`, 346 files, 3.8 MB. Restored into an isolated directory:
`npm ci`, typecheck, build and **42/42** tests passed.

**Latest sandbox snapshot**
`~/Desktop/kachi-fintech-sandbox_otp-sim_2026-11-15_153857`
111 files, 2.3 MB. Restored into an isolated directory: `npm ci` and **37/37**
tests passed. The live Flutter contract test also passed against a fresh
instance of this tree.

Earlier checkpoints remain on the Desktop:
- `kachi-fintech-sandbox_otp-sms_2026-11-15_152836` — 36/36
- `kachi-fintech-sandbox_providers-final_2026-11-15_144948` — 33/33
- `kachi-fintech-sandbox_accounts-final_2026-11-15_140352` — 32/32
- `kachi-fintech-sandbox_revenue_2026-11-15_135756` — 32/32
- `kachi-fintech-sandbox_customers_2026-11-15_133224` — 30/30
- `kachi-fintech-sandbox_pricing_2026-11-15_072912` — 22/22
- `kachi-fintech-sandbox_facade_2026-11-15_053722` — 21/21
- `kachi-fintech-sandbox_institutions-final_2026-11-15_044710` — 9/9

---

## DECISIONS SETTLED

- Fee on top; no float balance ("Available today" is remaining limit)
- Backend stack: Fastify + PostgreSQL; sandbox: Express + SQLite
- Stay signed in behind PIN/biometric; language and theme remembered
- Receive = payout; no wallet
- Limits/tiers come from the server; no approved limit means no quote
- Simulated data only in `preview/`
- Currency decimals from the server
- Route cards: You pay / Recipient gets; fee added on top
- Safeguard only when the server confirms it
- Expiry offers a new rate; one quote per visit; server clock
- Recipient check: match-only answer, never the registered name
- Authorize allowed on match; blocked on mismatch/not found; warning when
  unverifiable
- One idempotency key per authorization attempt; retries replay
- Facade errors use `{error:{code,message}}`
- Facade money flow uses the existing double-entry ledger, no facade balance
- Platform fee covers the PSP collection fee; default 150 bps
- Sandbox OTP codes visible by default; `FACADE_DEV_OTP=false` disables

---

## OPEN DECISIONS / BLOCKERS

These cannot be finished by engineering alone:

1. Lawyer before public launch, including where ID data may be stored.
2. Approval of safeguard wording.
3. Whether payouts to unverified names are acceptable.
4. Final wording for "if you were charged, contact support".
5. Final name, domain and trademark.
6. Partner conversations: SMS, mobile money aggregator, licensed bank/PSP.
7. Escrow partner, name-lookup access and payment collection callbacks.
8. Logo, privacy policy and final Swahili review.
9. The FX spread that covers the rate lock.
10. Finance/Legal approval of the chart of accounts and escrow treatment.
11. Approved tier limits and the daily-limit timezone decision.
12. KYC retention, encryption and data-residency decision.
13. Liquidity provider model, matching policy, match deadline and corridor
    exposure caps. Plan: `docs/P2P_MATCHING_PLAN.md`.
14. Invoice/export persistence and the signed-link policy.

Engineering blockers:
- Live SMS delivery: the sandbox real-SMS path is working from Vodacom SIM 1 (`0767304776`) to `+255714604777`; the production SMS partner is not configured.
- A real pricing source and approved spread (B2.2 works against the sandbox).
- Collection/payout provider contracts (B2.3/B2.4).
- Name-check provider.
- CrossPay market-depth source (sandbox has depth; CrossPay does not proxy it).
- Biometrics and app-side refresh-token handling (F5.3).

---

## HOSTING PLAN

- **Stage 0 now**: local Mac, $0
- **Stage 1**: partner sandboxes — Render ~$7–14 + free Supabase
- **Stage 2**: real-money pilot — Render + Supabase Pro ($25) + domain,
  ~$40–50/month

Not Vercel for the API (Hobby is non-commercial; serverless fits workers
poorly). Vercel only for a future website/admin dashboard. Private GitHub repo;
secrets only in host settings; staging separate from production.

### Database status (2026-11-15)

- The CrossPay API is PostgreSQL-native. Its tests run against **embedded
  PostgreSQL 17**; migrations, seed and verification scripts are in `server/`.
- **No Supabase project is configured yet.** There is no production database,
  no hosted connection string and no Render deployment.
- The sandbox uses **SQLite** for its own ledger and must not be moved into the
  CrossPay Supabase database.
- Supabase is a hosting choice, not a code dependency. Local development and
  tests do not need it.

**Decision: do not configure Supabase yet.** Wait until B2.3/B2.4 and the
matching engine have stable contracts. Then create the staging project:

1. Supabase project and region (data residency decision).
2. Separate migration and runtime roles; least privilege.
3. Apply the seven migrations; verify seed and reference counts.
4. Decide RLS posture (the API uses its own auth; direct client access stays
   closed).
5. Connection pooling for Render.
6. Backups/PITR and a restore drill.
7. Secrets only in host settings; staging separate from production.
8. Run `verify:local` and the full API suite against the hosted database.

Until then, embedded PostgreSQL remains the source of truth for tests.

---

## CURRENT PHASE AND NEXT STEPS

**Current phase**: PART 2 backend plus provider reference implementation.

Completed:
- Frontend plan items except F5.3 partial.
- B1 database foundation.
- B2.0 bootstrap and B2.1 idempotency.
- B2.2 provider-backed rates, estimate and quote.
- Sandbox provider reference implementation and `/api/v1` facade.
- Sandbox provider customers: PSP wallets, bank customers, KYC identities,
  dashboard panel, wallet debits/credits and provider rules.
- CrossPay account/clearing and revenue book: partner trust/operating accounts,
  fee/spread revenue routing.
- CrossPay HTTP SMS adapter for OTP delivery; disabled by default.
- CrossPay payment provider boundary and sandbox adapter: collections, payouts,
  refunds, bank accounts and transfers.
- Full live flow through the sandbox and real Flutter repositories.
- Verified snapshots of both projects.

Next, in order:
1. **B4.6 Phase C/D** — control-room SSE/event outbox, analytics charts/exports,
   configuration center (services, fees, spreads, tiers, provider settings,
   flags), approvals/versioning.
2. **B4.6 Phase E/F/G** — bookkeeping, trial balance, settlement/reconciliation,
   support cases and compliance.
3. **Bank payouts and KYC/name-check adapters** — mobile-money payout, refunds,
   callbacks, matching and the reconciliation worker are built; bank rails need
   an approved partner account contract.
4. **F5.3 remainder** — biometrics and app-side refresh-token handling.
5. Replace the sandbox pricing/collection/payout adapters with approved real
   providers when contracts exist.
6. Remove the sandbox testing-only `CROSSPAY` mirror after the admin books and
   reconciliation pass.

Git: branch `fix/theme-system` is local. B2.3/B2.4/B4 and the named-admin portal
are committed locally; nothing has been pushed.

---

## PROVENANCE NOTES

- The 2026-11-06 commits labeled "F3.7.x" contain work now tracked as F4.1
  (partial), F5.3 (partial), plus two kept extras (route comparison screen and
  Account tab hub). "F3.7" was never in the plan — F3 ends at F3.6.
- The original `FEATURE_SPEC/F3/F3.7.md` text remains recoverable in git history
  (commit `707b852`).
- Kept extras: route comparison screen
  (`lib/features/transaction/screens/route_comparison_screen.dart`) and the
  Account tab hub (`lib/features/account/screens/account_tab_screen.dart`).
- `lib/core/network/environment_config.dart` remains not built; write it fresh
  if a real-money release needs environment URLs and feature flags.

---

## Report End - No fluff. Just facts.
