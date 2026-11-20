# BUILD LOG

Append-only record of what was built, when, and what it left behind. One entry
per increment, newest last. **Nothing here is planned work - it is what the tree
actually contains.** The plan of record stays `MASTER_PROGRESS_REPORT.md`.

---

## 2026-11-07 - Unattended build pass (F4.1 finish, F4.2, F5.1, F5.2, F5.3 part)

**Session rule followed**: frontend only, additive edits, no new pub dependency,
no invented data in `lib/`, honest "not connected" states, full suite green before
each commit.

### Step 0 - documentation scaffolding
- Created `FEATURE_SPEC/INDEX.md` (every plan ID -> spec file -> real state) and
  this BUILD LOG.
- Localization consistency pass for the screens touched in this pass: every new
  or edited string now comes from `lib/core/localization/en.json` + `sw.json`
  (176 -> 261 keys in both, verified identical key sets). **Deferred and
  recorded**: the tracker screen's own status labels and `security_settings`
  strings were left as they are (verified screens, no churn) - see "Deferred".

### Step 1 - F4.1 status timeline
- `ApiEndpoints.tradeHistory`, `TradeEvent` model, shared `parseTradeStatus()`
  (the trade parser now uses it too), `TradeRepository.fetchTimeline`,
  `tradeTimelineProvider`, `TradeTimelineCard` wired into the tracker.
- Tests: `test/trade_timeline_test.dart`.

### Step 2 - F4.1 CSV export
- `ApiEndpoints.tradesExport`, `ExportTicket`, `TradeRepository.requestExport`,
  `tradeExportProvider`, history AppBar download action -> bottom sheet with the
  server link + Copy link (built-in `Clipboard`, no `share_plus`).
- Tests: `test/trade_export_test.dart`.

### Step 3 - F4.1 spending analytics
- `ApiEndpoints.tradesAnalytics`, `TradeAnalytics` / `CorridorSpend`,
  `TradeRepository.fetchAnalytics`, `analyticsProvider`, `AnalyticsScreen`
  (`/analytics`) + Account hub tile + history AppBar action.
- Tests: `test/analytics_screen_test.dart`.

### Step 4 - F4.2 market depth
- `ApiEndpoints.marketDepth`, `CorridorDepth`, `RatesRepository.fetchDepth`,
  `marketDepthProvider`, `MarketDepthScreen`; **the Rates shell tab is now this
  screen** (`_PlaceholderTab` deleted).
- Spec: `FEATURE_SPEC/F4/F4.2.md`. Tests: `test/market_depth_screen_test.dart`.
- `test/main_shell_screen_test.dart` updated for the two real tabs.

### Step 5 - F5.1 profile & limit bar
- `ProfileScreen` (`/profile`) using the existing `profileProvider` /
  `/me` model, with the daily limit bar; Account hub tile.
- Spec: `FEATURE_SPEC/F5/F5.1.md`. Tests: `test/profile_screen_test.dart`.

### Step 6 - F5.2 saved recipients CRUD
- `ApiEndpoints.beneficiary(id)`, `BeneficiaryRepository.add/update/remove`,
  `beneficiariesProvider.add/update/remove` (+ `saving`), `BeneficiariesScreen`
  (`/recipients`) with add/edit dialog and delete confirmation; hub tile.
- Spec: `FEATURE_SPEC/F5/F5.2.md`. Tests: `test/beneficiaries_screen_test.dart`.

### Step 7 - F5.3 remaining codable parts
- Language persistence: `lib/core/storage/language_store.dart`,
  `LocaleCodeNotifier(initial:)` + write-through on change, `main()` reads the
  stored code before the first frame.
- **Not built, by decision** (recorded in `FEATURE_SPEC/F5/F5.3.md`):
  biometrics (needs a `local_auth` dependency), stay-signed-in refresh
  (needs `POST /auth/refresh` on the server).
- Tests: `test/language_preference_test.dart`.

### Step 8 - preview + verification
- `preview/preview_overrides.dart` extended so the demo app shows history,
  timeline, export link, analytics, market depth and recipients; recipients really
  add/edit/delete for the session.
- `dart analyze lib/ preview/ test/` -> **No issues found**.
- `flutter test` -> **200/200 passing**.
- Preview web build + serve check recorded in `MASTER_PROGRESS_REPORT.md`.

### Blocked / not touched
- PART 2 (backend) - not in the repo; every endpoint above is documented in
  `docs/api_contract.md` and each screen shows "not connected" until it exists.
- `lib/core/network/environment_config.dart` - still backlog (real-money release).

### Deferred (deliberate, no churn on verified screens)
- Tracker screen status labels (`_statusLabel`, `_statusIcon`, `_statusColor`) and
  the security-settings / language-selector wording still use plain English
  literals; the new screens and the history screen use the dictionaries.
- Nothing else was deferred silently.

---

## 2026-11-10 - Theme repair (F1.2) and full dark-mode sweep

**Session rule followed**: no invented data in `lib/`, no new dependency, the
server stays the source of truth, nothing pushed.

### Step 1 - restore the build and persist the choice
- `ThemeStore` / `SecureThemeStore` moved to `lib/core/storage/theme_store.dart`;
  `main()` reads the saved language and theme mode before `runApp`, and falls
  back to the defaults when secure storage is unavailable.
- `AppThemeMode` (`light` / `dark` / `system`) maps to Flutter's `ThemeMode` in
  `app.dart`; `themeModeProvider` persists every change write-through.
- `/settings` is now a real hub (language, appearance, security). The Account
  tab tile opens it; every new string exists in both `en.json` and `sw.json`.

### Step 2 - one palette source
- `AppTheme` defines both palettes; screens read
  `Theme.of(context).colorScheme`. Dark scaffold `#12121C`, surface `#1E1E2E`,
  highest surface `#252538`, primary `#9FA8DA`, body text `#F1F2F6`, outline
  variant `#3A3D52`, error `#FF8A80`.
- Light `onSecondary` is black so emerald buttons meet the 4.5:1 text contrast.
- `test/app_theme_test.dart` checks WCAG AA contrast for surface/primary/
  secondary/error pairs in both palettes and that dark no longer paints light
  surfaces.

### Step 3 - sweep the screens
- 34 UI files (screens/widgets) replaced hardcoded `AppColors.navy/textPrimary/
  textSecondary/border/surface/background` and `Colors.white` surfaces with
  scheme colours.
- Only the brand/status palette (emerald, warning, danger, success) and the QR
  module paint stay fixed, by design.
- Removed 15 empty `TextStyle()` artifacts left behind by the earlier colour
  stripping; fixed a Settings subtitle that claimed fingerprint/Face ID before
  biometrics are wired.

### Step 4 - tests that do not race the clock
- `test/payment_provider_test.dart` now polls provider state through `_waitFor`
  instead of assuming a fixed 80-150 ms window; the assertions are unchanged.
- Theme coverage: `test/theme_provider_test.dart` (persistence + choices),
  `test/settings_screen_test.dart` (hub choices), `test/app_theme_test.dart`
  (contrast + dark surfaces).

### Verification
- `dart analyze lib test preview` -> **No issues found** (final tree).
- `flutter test -j 4` -> **210/210 passing**.
- Targeted rerun on the final tree (9 affected files) -> **45/45 passing**.
- `flutter build web --release -t preview/main.dart` -> **Built build/web**
  (578.2 s).

### Still open (not silently claimed as done)
- Biometrics: `local_auth` and `BiometricManager` are in the tree but are not
  wired into the app-lock gate; Android/iOS permission entries are still
  missing. The security screen correctly says "Not available yet".
- Stay signed in: needs `POST /auth/refresh` plus a validation call at boot.
- No push was made; the branch stays local until the product owner confirms.

---

## 2026-11-10 - Tracker scroll fix and a real support screen (F3.5)

**Session rule followed**: no invented data in `lib/`, no new dependency, the
server stays the source of truth, honest "not connected" states, nothing pushed.

### Tracker: scroll instead of overflow
- `trade_tracker_screen.dart` body is a `ListView` inside the same 480dp column.
- Contact support / Share invoice are pinned in `bottomNavigationBar`; terminal
  trades pin Done alone. The buttons stretch to the bar width.
- Amount rows right-align their values in an `Expanded` child; the six-stage
  status bar gives every stage an equal-width column, wraps its label and now
  reads its labels from the shipped dictionaries.
- Status/action/reference strings moved to `en.json` / `sw.json`; the 360x640
  tracker test proves the screen scrolls without horizontal or vertical
  overflow.

### Support: honest now, server-ready later
- `GET /config.support` is optional: `email`, `phone`, `whatsapp`, `hours`, all
  optional. `SupportInfo` is nullable on `AppConfig`; no channel is invented.
- New `/support` screen shows the trade reference/status/hash, copy actions and
  an optional message. It says "Checking support options..." while loading and
  "Support contact options are not available yet" when the server has none.
  Sending is not connected, so there is no fake send button: only copyable
  details and request text.
- Contact Support on the tracker now pushes `/support` with a typed
  `SupportTradeContext` (legacy map arguments still parse). Settings has a
  localized Help & support entry with no trade attached.
- `docs/api_contract.md` documents the optional support block.

### Verification (final tree)
- `dart analyze lib test preview` -> **No issues found**.
- `flutter test -j 4` -> **218/218 passing**.
- `flutter test test/trade_tracker_screen_test.dart` -> **3/3 passing** after the
  final pinned-bar layout.
- `flutter build web --release -t preview/main.dart` -> **Built build/web**
  (231.3 s).

### Still open (not silently claimed as done)
- Real support channel values and in-app ticket/message submission need the
  server. The app says so instead of faking a contact path.
- Biometrics and `POST /auth/refresh` stay-signed-in remain outside this fix.
- No push was made; the branch stays local until the product owner confirms.

---

## 2026-11-14/15 - B1 backend database foundation

**Session rule followed**: the Flutter tree is unchanged; the server is a new
`server/` workspace. No mocks or invented operational data. No push.

### Documentation and contract first (B1.0)
- Approved `docs/B1_DATABASE_PLAN.md` for build with explicit provisional
  assumptions for the four deferred decisions.
- Reconciled `docs/api_contract.md`: beneficiary `POST`/`PATCH`/`DELETE`,
  `GET /market/depth`, invoice/share endpoints, payout-rail `kind`, refresh
  rotation and idempotency replay semantics.
- Linked the plan from `MASTER_PROGRESS_REPORT.md`.

### Database (B1.1–B1.7)
- Seven forward-only migrations under `server/db/migrations/`:
  reference data; identity/KYC/OTP/refresh; recipients/quotes/trades; idempotency;
  financial operations; double-entry ledger; transition and append-only guards.
- Idempotent reference seed with East African countries, currencies, carriers,
  hubs, 18 payout rails, a starter tier and provisional ledger accounts for six
  currencies. Support, tier limits and corridor pricing are deliberately empty.
- Checksum-locked migration runner, seed runner, `npm run verify` and
  `npm run verify:local`.
- ERD and migration/incident runbook in `server/db/`.

### Application primitives
- `crypto.ts`: AES-256-GCM, HKDF-derived keys, HMAC lookups, stable request
  hashes.
- `idempotency.ts`: concurrent acquisition, replay, different-body rejection,
  encrypted response snapshots, pruning.
- `quotes.ts`: single-use consumption and expiry worker.
- `auth/otp.ts`: hashed codes, one active code per phone, attempt limits.
- `auth/refresh-tokens.ts`: hashed tokens, rotation families, revocation on reuse.
- `ledger.ts`: balanced posting, append-only history, reversing entries.

### Verification
- `npm run typecheck` -> **clean**.
- `npm test` -> **31/31 passing** against embedded PostgreSQL 17, covering
  migrations, seed, `/config`, quote expiry, trade timeline, concurrent
  idempotency, ledger balance/immutability, OTP and refresh rotation, and
  encryption.
- `npm run verify:local` -> `ok: true`, 7 migrations, 6 currencies, 18 payout
  rails, 48 provisional ledger accounts, no support/limits/corridors.
- Desktop snapshots created before the build, after the docs commit and after
  the B1 build. All passed `git fsck` and matching tree hashes; the B1-built
  snapshot was restored into an isolated directory and passed `npm ci`,
  typecheck and 31/31 tests. Snapshots are never overwritten.

### Still open (not silently claimed as done)
- Finance/Legal approval of the chart of accounts and escrow treatment.
- B2 HTTP endpoints, real SMS/pricing/KYC providers and log redaction tests.
- Deferred product decisions: KYC retention, daily-limit timezone, invoice/export
  persistence and P2P matching.
- No push was made; the branch stays local until the product owner confirms.

---

## 2026-11-15 - B2.0 HTTP bootstrap

**Session rule followed**: no frontend changes, no invented pricing or queue
data, no fake SMS delivery, no push.

### HTTP service
- Fastify service with secure-by-default authentication, structured
  `{error:{code,message}}` responses, 1 MiB body limit, redacted authorization
  and idempotency headers, and public-route allow-list.
- `GET /health`, `GET /config`.
- OTP request/verify with six-digit hashed codes, attempt limits and
  database-backed per-phone/per-IP rate limiting.
- HS256 access tokens (15 minutes) and rotating refresh tokens (30 days);
  reuse revokes the family.
- `GET /me` with tier, currency-derived daily limit and derived usage.
- `PUT /me/kyc` with encrypted ID/TIN storage, duplicate detection and manual
  review status `pending`.
- Recipient list/create/update/delete with ownership checks, encryption and
  idempotent replay.
- Honest `503` for rates, market depth, trade endpoints and name checks.

### Verification
- `npm run typecheck` -> clean.
- `npm test` -> **36/36 passing**, 8 suites, embedded PostgreSQL 17.
- HTTP tests cover config shape, OTP wrong/correct codes, KYC gate, `/me`,
  recipient replay/conflict/update/delete, refresh reuse and rate limiting.
- `npm run verify:local` -> `ok: true` (7 migrations; B1 reference-data counts
  unchanged).

### Still open (not silently claimed as done)
- Real SMS partner; OTP returns `SMS_NOT_CONFIGURED` until configured.
- Pricing source, payout provider and name-check provider; trade/rates/name
  endpoints return `503` rather than fake data.
- KYC provider/manual review, tier limits, and the deferred policy decisions.
- No push was made; the branch stays local until the product owner confirms.

---

## 2026-11-15 - B2.2 rates, estimate and quote

**Session rule followed**: no frontend changes, no invented rates or limits, no
fake payment, no push.

### Provider boundary
- New `PricingProvider` with `DisabledPricingProvider` (default, honest 503)
  and `SandboxPricingProvider` (reference provider).
- The sandbox gained userless, read-only `/api/v1/sandbox/pricing/estimate` and
  `/pricing/quote` endpoints behind the operator key. They return rate, fee,
  route availability, estimates and a five-minute lock window without creating
  a sandbox quote.
- Provider responses are validated with Zod; outages and malformed payloads
  become `503 PRICING_UNAVAILABLE`.

### API
- `GET /rates` now serves provider rates when configured.
- `GET /trade/estimate` returns the provider estimate for a signed-in user.
- `POST /trade/quote` requires verified KYC, enforces the approved daily limit
  when the send currency matches the limit currency, and stores the quote plus
  its route snapshot transactionally.
- `POST /trade/initiate` now returns `503 PAYOUT_NOT_CONFIGURED`, because
  pricing is connected but payment is not.
- Quote persistence validates fee math, route uniqueness, one recommendation
  and the lock window before touching the database.

### Verification
- `npm run typecheck` -> clean.
- `npm run build` -> clean.
- `npm test` -> **42/42 passing**, 10 suites, embedded PostgreSQL 17.
- New tests cover provider paths/auth/query parameters, 422 rejection, 503
  outage, malformed data, rate/estimate/quote responses, quote persistence,
  KYC gate, daily limit and the disabled default.
- Live check against the running sandbox returned KES→TZS 0.057143, fee 150
  bps, payout 17,500 TZS minor and total debit 101,500 KES minor for a
  100,000 KES minor send.
- The B2 bootstrap snapshot was restored into an isolated directory and
  re-verified: `npm ci`, typecheck, build and **36/36** tests passed.
- A new snapshot at commit `5e00d9e` is
  `~/Desktop/crosspay_app_2026-11-15_073154_b2.2-pricing`. Restored into an
  isolated directory: `npm ci`, typecheck, build and **42/42** tests passed.
  Snapshots are never overwritten.

### Still open (not silently claimed as done)
- B2.3 initiation/collection and B2.4 payouts/refunds.
- Market depth is not proxied by CrossPay; the sandbox still serves it.
- Real pricing and approved tier limits are Product/Finance decisions.
- No push was made; the branch stays local until the product owner confirms.

---

## 2026-11-15 - Planning: provider customers, matching engine and database status

**No code built in this step.** Plans and boundaries were corrected.

- The sandbox is a provider simulator only. It must enforce real provider
  rules and must not contain CrossPay's matching engine or quote logic.
- The matching engine lives in CrossPay. It runs only on funded/escrowed trades:
  FIFO, full-fill, platform-quoted rate, two-leg payout saga with compensation.
- Provider customers come first: PSP wallets, bank customers and KYC identity
  records, each with a ledger account and balance.
- Build order: sandbox provider customers → CrossPay provider adapters →
  B2.3/B2.4 payments → matching engine → app integration → liquidity/partial
  fills.
- CrossPay decides the customer quote and spread, not the underlying market
  rate. It follows provider rate validity, limits, cutoffs and settlement rules.
- Supabase is intentionally not configured yet. The API tests use embedded
  PostgreSQL 17; the sandbox uses SQLite. Configure a hosted staging database
  only after the payment and matching contracts stabilize.

Plans:
- `kachi-fintech-sandbox/docs/INSTITUTION_CUSTOMERS_PLAN.md`
- `docs/P2P_MATCHING_PLAN.md`
- `MASTER_PROGRESS_REPORT.md` database status section

---

## 2026-11-15 - Sandbox provider customers

**No CrossPay frontend/API code changed.** The provider side now has named
customers.

- PSP wallets with real ledger accounts; cash-in/cash-out; frozen/closed
  states; prefix and currency rules.
- Bank customers under each bank institution; deposit/withdraw/statement.
- KYC identity registry with hashed IDs and masked values.
- Unified `/api/sandbox/institutions/:idOrCode/customers` API and a dashboard
  **Customers** panel with counts, funding, freeze and statements.
- Collections debit the payer wallet; payouts and refunds credit the
  recipient/payer wallet. Legacy wallet-less rows keep clearing postings.
- Strict mode is opt-in through `PSP_REQUIRE_WALLET=true` or a dynamic PSP
  `config.requireWallet=true`.
- The facade auto-provisions a funded demo wallet after verified KYC unless
  disabled. The opening balance is a real ledger cash-in.
- Seeded demo wallets for the dashboard, contract tests and live app test.

Verification: sandbox **32/32** tests pass (14 facade + 9 simulator + 9
provider customers). The live Flutter contract test passed against a fresh
server, and a TZS→KES wallet-backed smoke debited the payer wallet by 101,500
TZS and credited the recipient by 571,430 KES minor.

Still open: strict KYC identity verification, CrossPay provider adapters,
matching engine (CrossPay only).

---

## 2026-11-15 - Account taxonomy and clearing boundary

**No CrossPay app/API code changed.** The sandbox now distinguishes provider
customer accounts from CrossPay partner accounts.

- `sandbox_bank_accounts` carries `owner_type` (`CUSTOMER`, `CROSSPAY`,
  `TRUST`) and `purpose` (`CUSTOMER_DEPOSIT`, `SETTLEMENT`, `TRUST`,
  `CLEARING`, `OPERATING`, `LEGACY`).
- Customer accounts belong to the PSP/bank. CrossPay's accounts at a partner
  bank are settlement/clearing/trust accounts, never customer accounts.
- Partner accounts can be created under any bank; Stanbic TZ/KE are seeded
  examples of a group with a shared cross-border balance sheet. They start at
  zero and are funded by real flows, not a demo mint.
- The facade resolver scans partner accounts (trust first) and does not
  hardcode a bank. `PARTNER_BANK_<currency>` / `PARTNER_BANK` can select one.
- Bank-route collections credit the partner trust account; payout releases from
  trust. The dashboard shows institution, type, purpose and owner, and has a
  partner-account form.
- Legacy `ACC_KE_002`/`ACC_TZ_002` rows are relabeled `settlement` /
  `CROSSPAY` / `LEGACY`; they are not customer accounts.

Verification: sandbox **32/32** tests pass. The CrossPay book now recognises
fees and settles them to operating cash, mirrored by a provider-book debit to
`CROSSPAY-PAYABLE` and a credit to the partner operating account
(`CPA-OPERATING-...`). Partner reconciliation statements remain planned.

---

## 2026-11-15 - CrossPay revenue book

**No CrossPay app/API code changed.** CrossPay's commission route is now explicit.

- The ledger has `PROVIDER` and `CROSSPAY` books; a journal cannot mix them.
- CrossPay accounts: provider receivable, fee revenue, FX spread revenue,
  operating cash, trust asset and beneficiary payable.
- Provider book keeps `CROSSPAY-PAYABLE` for the platform fee the PSP holds on
  CrossPay's behalf; the PSP fee stays in provider fee revenue.
- On collection, the net platform fee is recognised as a CrossPay receivable
  and fee revenue. `POST /api/sandbox/revenue/settle` moves it into CrossPay
  operating cash. It never touches customer wallets or trust/escrow funds.
- The dashboard has a **CrossPay Revenue** panel with revenue, receivable,
  operating cash and trust/beneficiary balances, and a settle action.
- Provider/customer accounts and CrossPay partner accounts remain separate;
  Stanbic is only an example, any bank with a shared cross-border balance sheet
  can be used.

Verification: sandbox **32/32** tests pass. Still planned: the provider-side
mirror of the fee settlement and partner reconciliation statements.

> **2026-11-16 correction**: this book is a testing-only stand-in, not CrossPay's
> home. CrossPay's real fee income is money in its bank/PSP operating accounts
> and is recorded in the CrossPay admin bookkeeping section. The sandbox book
> must be removed when that section exists. See
> `docs/REVENUE_AND_BOOKKEEPING.md`.

---

## 2026-11-15 - HTTP SMS and OTP delivery

**No frontend changes.** CrossPay's OTP path now has a real delivery adapter.

- `HttpSmsSender` posts `{ recipient, message, senderId? }` to `SMS_API_URL`
  with an optional `x-api-key`.
- `SMS_PROVIDER=disabled` remains the default and returns
  `503 SMS_NOT_CONFIGURED`; `SMS_PROVIDER=http` enables delivery.
- The adapter validates non-2xx, `{ success: false }`, timeouts and plain 2xx
  responses; it never includes the OTP in an error.
- The sandbox `/v1/send-sms` route is a compatible gateway. Provisional SIM
  for the sandbox is `+255767304776` (local `0767304776`); it is configured on
  the device, not hardcoded.
- Tests: HTTP adapter contract, disabled path, live local gateway delivery and
  verification. CrossPay API suite is **47/47**, 11 suites.
- Plan: `docs/OTP_WIRING_PLAN.md`.
- Sandbox real-SMS path added: `FACADE_SMS_DELIVERY=true` calls the existing
  protected `/v1/send-sms` route as the CrossPay tenant, hides `sandboxCode`,
  and enforces `SMS_ALLOWED_RECIPIENTS`. GasLink and the protected SMS/AI files
  are untouched. A real test SMS was dispatched to `+255714604777` from the
  provisional SIM `+255767304776`.
- Sandbox suite: **37/37** (14 facade + 9 simulator + 10 provider customers +
  4 real-SMS). SIM pinning (`FACADE_SMS_SIM_SUBSCRIPTION_ID=1`) sends CrossPay
  OTP from Vodacom SIM 1 without changing the shared/default SIM.

Still open: configure the production SMS partner/sender ID and delivery
monitoring.

---

## 2026-11-15 - Payment provider adapter

**No frontend changes.** CrossPay now has a provider boundary for payments.

- `PaymentProvider` interface for collections, payouts, refunds, bank accounts
  and same-currency transfers.
- `SandboxPaymentProvider` maps to the sandbox PSP/bank primitives with
  `x-api-key` and `Idempotency-Key`.
- `DisabledPaymentProvider` is the default and returns
  `PAYMENT_PROVIDER_NOT_CONFIGURED`.
- 4xx provider answers become `PaymentRejectedError`; 5xx/network/timeouts
  become `PaymentUnavailableError`; malformed bodies are rejected.
- Added sandbox `POST /api/sandbox/bank/transfer` for the transfer primitive.
- Config: `PAYMENT_PROVIDER=disabled|sandbox`, `SANDBOX_PAYMENTS_URL`,
  `SANDBOX_PAYMENTS_KEY`, `PAYMENTS_TIMEOUT_MS`.
- Tests: **53/53**, 12 suites, plus a live transfer smoke from
  `CRDB-DEMO-001` (2,000,000 TZS → 1,999,000 after a 1,000 TZS transfer).
- Plan: `docs/PAYMENT_ADAPTERS.md`.

Next: B2.3 `/trade/initiate` and B2.4 payouts/refunds.

---

## 2026-11-16 - Revenue book is a testing stand-in, not CrossPay's home

**No CrossPay app code changed.** The accounting boundary is now explicit.

- CrossPay's real money lives in its **bank/PSP operating accounts**
  (`CPA-OPERATING-...`), not in the sandbox.
- The CrossPay admin **bookkeeping section** is the home of collective income;
  every fee/spread entry must trace to a trade, a provider statement and a
  bank/PSP operating account line.
- The sandbox `CROSSPAY` book is retained for now but labelled **testing-only**
  in code, API (`testingOnly: true`), dashboard and docs. It must be removed
  when the admin bookkeeping exists.
- Sandbox settlement now posts **two linked journals**: provider book clears
  `CROSSPAY-PAYABLE` into `CPA-OPERATING-...`; the mirror book moves receivable
  to operating cash. Refunds reverse both the provider fee journal and the
  mirror fee revenue.
- Rail-based fees remain: P2P/mobile money 150 bps, bank 250 bps, the same in
  every corridor; bank costs more.
- OTP accepts any valid E.164 phone by default; `SMS_ALLOWED_RECIPIENTS` is an
  optional lockdown (`*` or empty = all). SIM 1 pinning unchanged.
- Rule: `docs/REVENUE_AND_BOOKKEEPING.md`.
- Verification: sandbox **37/37**; live summary shows TZS 485 settled to
  `CPA-OPERATING-STANBIC-TZ-TZS` and KES 485 receivable/payable, all labelled
  testing-only.

---

## 2026-11-16 - B2.3 collections and B2.4 payouts, refunds and callbacks

CrossPay can now collect, pay out and refund end to end through the sandbox.

- `POST /api/v1/trade/initiate` consumes a quote once, re-checks the daily
  limit in the send currency, snapshots the encrypted recipient and starts one
  deterministic collection. The `CP-...` reference is also the provider
  idempotency key.
- Added trade list/detail/history, payment-claim and cancel routes. A claim
  never marks a trade paid without the provider; a cancel refuses with
  `ALREADY_PAID` after confirmation.
- Collection posting: partner trust cash / trade payable for principal, and
  partner trust cash / fee revenue for the **net** fee after the provider fee.
- A late success after cancellation is booked and refunded; the trade stays
  `cancelled`.
- B2.4 `POST /trades/:id/disburse` starts/resumes a mobile-money payout. Success
  posts two linked single-currency FX journals (send and receive) plus the
  payout journal. A failure/rejection refunds the payer and reverses the
  collection journals. Bank rails return `503 PAYOUT_RAIL_NOT_CONFIGURED`.
- B2.4 `POST /trades/:id/refund` asks the provider first, then reverses the
  deposit and fee journals. Refusing after a completed payout is
  `PAYOUT_ALREADY_SENT`.
- `POST /api/v1/webhooks/payments/:provider` verifies HMAC-SHA256 over
  `<timestamp>.<raw body>`, bounds clock skew and uses
  `(provider, provider_event_id)` for replay protection. A failed event stays
  retryable.
- The sandbox adapter now discovers the PSP by currency and phone prefix from
  `GET /api/sandbox/psp/providers`; no provider codes are hardcoded in CrossPay.
- Added `6000 Provider fees` to the provisional chart of accounts.
- Verification: Node **74/74**, 15 suites, typecheck clean. Live smokes:
  `smoke:b2.3` (collection + claim), `smoke:b2.4` (collection → FX → payout),
  `smoke:webhooks` (real signed collection and payout callbacks).
- Detail: `docs/B2_3_B2_4_IMPLEMENTATION.md`.

Next: B4 P2P matching engine, bank payout rails, scheduled reconciliation and
KYC/name-check adapters.

---

## 2026-11-16 - B4 P2P matching engine v1

Funded opposite trades now match and pay both legs.

- Migration `0008_p2p_matching.sql`: `match_rate`, `p2p_match_events`,
  `match_deadline_at`, `p2p_corridors`, queue index and the new
  `p2p_settlement`/`p2p_compensation` journal kinds.
- `P2P_ENABLED=false` by default; matching also needs an enabled
  `p2p_corridors` row with an exposure cap. No corridor is seeded.
- FIFO full-fill: oldest opposite `escrowed`/`matching` mobile-money trade,
  both rows locked, deterministic trade-id tie-break, `p2p_matches` unique pair.
- Match settlement is single-currency: release the counterpart's principal,
  create the payout payable, book the residual to `3100` spread revenue. No FX
  journal for a matched pair.
- Two-leg saga: first-leg failure refunds both; second-leg failure refunds the
  second and books a `p2p_compensation` treasury advance.
- Deadlines expire and refund. Claim/webhook auto-match a newly funded trade.
- Added `POST /trades/:id/match` and `POST /matches/:id/disburse` as
  server/ops triggers; the app only displays `matching`/`matched`.
- Verification: Node **79/79**, 16 suites, typecheck clean. Live `smoke:b4`
  used two real sandbox collections in opposite directions; both payouts
  completed, match `released`, every journal balanced.
- Detail: `docs/B4_MATCHING_IMPLEMENTATION.md`.

Remaining: scheduled sweep, liquidity-provider standing orders, ops dashboard,
bank payout rails, KYC/name-check adapters, production corridor approvals.

---

## 2026-11-16 - Reconciliation worker

- `src/runtime.ts` now builds the process context once for both the HTTP server
  and the worker, so provider/config construction cannot drift.
- `npm run worker` runs `runWorkerPass` every `WORKER_INTERVAL_SECONDS`
  (default 30) or once with `WORKER_ONCE=true`.
- Each pass expires stale quotes, expires/refunds past-deadline match trades,
  resumes locked matches, resumes direct payouts and retries pending refunds.
- All actions are idempotent by posting key, provider reference or refund row;
  `test/worker.test.ts` covers each path.
- Verification: Node **84/84**, 17 suites, typecheck clean.

Next: liquidity providers and ops dashboard, bank payout rails, KYC/name-check
adapters, analytics/export and invoice/share handlers.

---

## 2026-11-16 - Market depth, analytics and CSV export

- `GET /market/depth` now returns real funded-queue depth for enabled
  `p2p_corridors` with an operator-supplied `estimated_settle_seconds`
  (migration `0009_market_depth.sql`). Corridors without an estimate are
  omitted; no wait time is invented.
- `GET /trades/analytics` aggregates completed trades in the account's limit
  currency. Totals use the highest-volume receive currency because the contract
  has one received currency; corridors list each receive currency separately.
- `GET /trades/export` issues a five-minute, single-purpose download token;
  `/trades/export/download` is public but token-authenticated and streams the
  user's CSV. Without `PUBLIC_API_URL` the endpoint returns
  `503 EXPORT_NOT_CONFIGURED`.
- Verification: Node **88/88**, 18 suites, typecheck clean.
- `invoice/share` remain honest `503`; they need a QR generator and share URL.

Next: liquidity providers and ops dashboard, bank payout rails, KYC/name-check
adapters, invoice/share handlers.

---

## 2026-11-16 - B4.4 liquidity providers and B4.6 Phase A admin

- Migration `0010`: corridor min/max bounds, `p2p_corridor_exposure` view,
  `liquidity_providers`, `liquidity_orders`, LP match columns, LP traceability
  on journals, and the `2050` LP payable account.
- LP standing orders are allowlisted, pre-funded, expiring and capacity-limited.
  Creating an order books the prefund (`1000` cash / `2050` LP payable) against
  an operator reference; cancelling an unused order returns the remaining
  prefund. Matching uses no organic counterparty first, then the cheapest
  eligible LP order.
- LP payouts post one send-currency settlement (user payable → LP payable +
  spread) and one receive-currency settlement (LP payable → user payable), then
  the normal payout. A failed LP payout refunds the customer and returns the
  reserved capacity exactly once.
- Migration `0011`: append-only `admin_audit_log`; every Phase A admin write
  records actor `env-admin`, resource, before/after, reason and IP.
- Phase A admin: `/admin` HTML shell, `ADMIN_API_KEY` JSON auth, overview,
  corridor policy, LP provider/order controls, manual match/disburse triggers.
- Worker also expires stale LP orders.
- Verification: Node **93/93**, 19 suites, typecheck clean.
- Plan for named admin users, RBAC, 2FA, bookkeeping, settlement and
  reconciliation: `docs/ADMIN_PANEL_PLAN.md`.

Next: admin identity/bookkeeping/reconciliation, bank payout rails,
KYC/name-check adapters, invoice/share handlers.

---

## 2026-11-16 - B4.6 named-admin web portal (Phase A/B)

- New separate `admin-web` process in `server/src/admin-web/` with its own
  Fastify server, EJS views, CSS and minimal JS. Same package/repo, separate
  container/entrypoint (`npm run admin:dev`, `npm run admin:start`).
- Migration `0012`: `admin_users`, roles, server-side sessions, login
  challenges, recovery codes, login attempts, TOTP replay guard and
  `admin_audit_log.admin_user_id`.
- Auth: Argon2id, TOTP enrolment with terminal/QR bootstrap
  (`npm run admin:create`), challenge cookies, HttpOnly/SameSite sessions,
  CSRF/origin checks, session revocation, login rate limit and TOTP replay
  rejection.
- RBAC: viewer, ops, finance, compliance, superadmin. Last active superadmin
  cannot be suspended/demoted.
- Pages: overview, control-room polling snapshot/activity feed, analytics
  tables, corridors, liquidity providers/orders, trade search/detail, audit,
  admin-user management.
- Ops actions: re-check provider, match, disburse/resume, payout retry (match
  aware), refund, refund retry. Every action is named-admin audited.
- Security headers: CSP, frame denial, noindex, no-store HTML, HSTS when HTTPS.
- Renamed the ops-admin track to **B4.6**; B4.5 is the app matching states.
- Verification: Node **100/100**, 20 suites, typecheck clean. Portal tests cover
  login, TOTP replay, CSRF, RBAC, pages, first-login enrolment and audit.
- Detail: `docs/ADMIN_WEB_IMPLEMENTATION.md`; full plan:
  `docs/ADMIN_PANEL_PLAN.md`.

Next: Phase D configuration center, settlement/reconciliation, Phase G
support/compliance, and removal of the sandbox `CROSSPAY` mirror.

---

## 2026-11-17 - B4.6 Phase C control room, analytics windows and bookkeeping

- Migration `0013`: `admin_activity_events` append-only outbox fed by database
  triggers for trade events, matches, payouts, refunds, LP orders and admin
  audit. Payloads carry references/statuses/currencies/minor amounts, never
  recipient PII. `pg_notify('admin_activity', id)` is installed; the portal
  currently uses a bounded shared poller.
- New `ActivityStream`: one 2-second poller fans out to every browser, reads a
  10-second overlap and dedupes by id. Control room SSE catches up from
  `Last-Event-ID`, sends heartbeats, reconnects after 10 minutes and falls back
  to the 5-second JSON snapshot. Source filter and pause/buffer in the UI.
- Overview now reports oldest funded trade/match/payout/refund ages and emits
  SLO alerts.
- Analytics windows `24h|7d|30d|all`, funnel by send currency, ledger-backed fee
  and spread revenue, provider success rates, compensation/provider costs and
  refund reasons. No currency totals are mixed.
- Read-only bookkeeping: `ledger:read` permission, debit-positive trial balance
  per currency, journal browser filters, journal detail with lines, balance
  check, reversals and FX partners. No editing, “mark as paid” or statement
  matching claim.
- Fixed the build asset copy so repeated builds replace `views/`/`public/`
  instead of nesting `public/public`.
- Migration timing is clamped at zero: a clock step during a long migration no
  longer fails a deploy on `execution_ms >= 0`.
- Verification: Node **102/102**, 20 suites, typecheck clean, production build
  contains both new EJS views.

Next: Phase D configuration center, Phase F settlement/reconciliation and
Phase G support/compliance.

---

## 2026-11-17 - B4.6 Phase G manual support workspace

- Migration `0014`: `support_cases`, append-only `support_case_messages`,
  `support_canned_replies` and append-only `support_pii_reveals`. A case belongs
  to one customer and optionally one trade; the database refuses a trade from a
  different customer. Case references are `CS-YYMMDD-XXXXXX`.
- Permissions: `support:read`/`support:write` for ops, compliance and
  superadmin; `pii:reveal` for compliance and superadmin only. Viewer and
  finance cannot read support cases.
- Pages: case queue, new case from a customer/trade, customer 360, case detail
  with append-only thread, state/assignee, canned replies, PII reveal and
  provider-gated SMS reply.
- Notes are internal; SMS replies are customer-visible. Message bodies/authors
  cannot be rewritten or deleted. Only SMS delivery state can move
  `pending → sent/failed`; a failed gateway keeps the text and code, never marks
  it sent.
- Phone numbers stay masked to the last four digits; full phone and decrypted
  beneficiary account require permission plus a 5-300 character reason. Each
  reveal writes `support_pii_reveals` and admin audit; the control room gets a
  warning event with field names only.
- Support activity is trigger-fed and excludes subjects, names, phone numbers
  and message bodies; message events carry channel/visibility/delivery and body
  length. Support audit rows are de-duplicated in the control room because the
  support triggers already emit the event.
- SMS uses the existing `SmsSender`; disabled is an honest `503`, the HTTP
  sender now shares one free-text path with OTP, and the test fake captures both.
- Verification: Node **105/105**, 20 suites, typecheck clean.

Next: Phase D configuration center, Phase F settlement/reconciliation and the
remaining compliance queues.

---

## 2026-11-18 - B4.6 Phase D configuration v1

- Migration `0015`: `admin_config_changes` (immutable proposals, one pending
  change per setting, two-person decision), `service_controls` (emergency
  quote/trade pauses) and the `config` activity source.
- Support contacts (`support_settings`) and tier daily limits (`tier_limits`)
  now use propose/approve. A different finance/superadmin must approve; the
  proposer cannot approve their own change. Approval applies the value and
  publishes the next `config_versions` row in the same transaction.
- Rollback is a new proposal built from the immutable `before` snapshot; it is
  never a silent write. Rejection/cancellation never applies the value.
- Emergency service controls are superadmin-only and immediate; every change is
  audited and emitted to the control room. `POST /trade/quote` and
  `POST /trade/initiate` return `503 SERVICE_PAUSED` while paused. Rates,
  estimates, payouts, refunds and existing matches continue.
- `GET /config` includes an optional `service` block while paused or when a
  maintenance message exists. The app banner UI is not connected yet.
- Fees remain provider-owned. The config page shows declared 150/250 bps against
  provider-observed fee bps from the last seven days and labels mismatches. No
  fee editor was added, because it would create a second source of truth for a
  quote the customer already accepted.
- Added `/config` and `/config/changes/:id` pages, config permissions, config
  audit and trigger-fed config activity without payload values.
- Verification: Node **110/110**, 20 suites, typecheck clean.

Next: configuration remainder (provider settings/flags/banners/effective dates,
fee editor after provider reconciliation), Phase F settlement/reconciliation
and compliance queues.

---

## 2026-11-18 - B4.6 Phase F reconciliation v1

- Migration `0016`: `settlement_statements`, append-only `settlement_lines`,
  `reconciliation_exceptions` and the `reconciliation` activity source.
- Manual CSV paste import for provider or bank/PSP operating-account statements,
  scoped to one source and currency, max 5,000 lines. File hash is unique per
  source/currency; duplicate imports are refused. Statement content and lines
  are immutable.
- Exact matching only: provider reference + amount + currency + terminal status
  for collections/payouts/refunds, plus the expected journal; bank/fee/transfer
  lines need an explicit CrossPay `posting_key` whose journal has the same
  currency and debit total.
- Typed exceptions: unmatched reference, amount/currency/status mismatch,
  missing journal, duplicate reference, unmatched journal, unsupported line.
  Nothing is auto-corrected.
- Finance/superadmin resolve exceptions with a required note; closing requires
  every exception resolved and a required close note. Closing is final and does
  not assert a bank balance matched.
- Reconciliation pages, permissions, audit and activity added. Activity carries
  counts/types, never line descriptions or resolution notes.
- Honest v1 limits: no live provider API/bank feed/file upload, no automatic
  missing-in-statement detection, no fee-line matching without a posting key,
  no correction/re-open flow and no bank balance matching.
- Verification: Node **112/112**, 20 suites, typecheck clean.

Next: reconciliation remainder (live feeds, missing-in-statement detection,
correction flow), configuration remainder and compliance queues.

---

## 2026-11-18 - B4.6 reconciliation v1.1 missing-in-statement detection

- Migration `0017`: statements carry `missing_count`; reconciliation exceptions
  may reference an internal provider row instead of a statement line and add
  the `missing_in_statement` kind.
- Provider imports now check both directions: statement line → internal record →
  journal, and confirmed collections / paid payouts / paid refunds in the same
  period and currency whose provider reference is absent from the statement.
- Missing items are separate from statement line counts, visible on the
  statement detail, and block close until resolved. Bank-side missing detection
  remains out of scope because a bank line has no provider reference in v1.
- Activity and audit include missing counts without line details or notes.
- Verification: Node **112/112**, 20 suites, typecheck clean.

Next: live statement feeds/file upload, bank-side missing detection,
correction/re-open, configuration remainder and compliance queues.

---

## 2026-11-19 - Compliance KYC review queue

- Migration `0018`: KYC review fields (`reviewed_by_admin_id`, `reviewed_at`,
  `review_note`), immutable decided rows, append-only history and the
  `compliance` activity source.
- `/compliance/kyc` queue for pending/verified/rejected submissions, oldest
  pending first. Customer phone is masked; identity is shown as type + last4.
  The full encrypted identity number is never decrypted or rendered.
- Approval changes the verification to verified and the customer to
  `kyc_status='verified'` in one transaction. Rejection requires a rejection code
  and a 5-300 character note, and sets both rows to rejected. Only pending can be
  decided. Rejected customers can submit a new application.
- Reviewer, decision time and note are stored; audit and control-room activity
  carry status/account/ID type/rejection code only, never legal name or identity.
- Permissions: `kyc:read`/`kyc:review` for compliance and superadmin. Ops,
  finance and viewer cannot read the queue.
- Verification: Node **114/114**, 20 suites, typecheck clean; Flutter analyzer
  clean after restoring the generated package config that had been removed for
  snapshot disk space.

Next: reconciliation remainder, configuration remainder and sanctions/name-check
queues.

---

## 2026-11-19 - recovery code login, statement upload and app banner

- Admin auth: `/login/recovery` consumes one unused recovery code after the
  password step, creates a normal session, audits `admin.recovery_login` and
  rejects reuse. Recovery codes remain hashed and single-use.
- Reconciliation: the import form accepts a CSV file upload (2 MB, one file) or
  pasted text. Multipart CSRF is validated inside the import route before any
  parsing/write; other multipart routes are refused.
- App: `/config.service` is now parsed by the Flutter `AppConfig` and rendered as
  a maintenance banner above the signed-in tabs, showing the operator message or
  which new requests are paused.
- Fixed the analyzer false alarm caused by deleting `.dart_tool` for snapshot
  space: `flutter pub get` restored package resolution and `flutter analyze`
  returns **No issues found**.
- Verification: Node **115/115**, 20 suites; typecheck clean; production build
  clean; targeted `main_shell_screen_test.dart` passed; Flutter analyzer clean.

Next: live statement feeds, bank-side missing detection, configuration
remainder and sanctions/name-check queues.

---

## 2026-11-19 - invoice links, linked corrections, scheduled banners, stay signed in and LISTEN/NOTIFY

**Session rule followed**: server is the source of truth, no invented
operational data in `lib/`, money stays in currency-minor units, nothing pushed.

### 1 - server-issued invoice links in the app
- Migration `0019` stores one invoice per trade: a 72-hour window, token hash
  for lookup, encrypted token at rest, and a `verification_hash`.
- `GET /trades/:id/invoice` returns `tradeId`, `amountMinor`, `currency`,
  `validUntil`, `qrCodeUrl` and `shareUrl`; `POST /trades/:id/share` reuses the
  same invoice behind an idempotency key. Public `/pay/:token` renders the payer
  page and `/api/v1/invoices/:token/qr.png` renders the QR.
- The Flutter invoice screen now loads that payload, formats `amountMinor` with
  the currency's decimals, displays the server expiry, copies the server
  `shareUrl` and shows the real network QR image. The fake QR painter and the
  fake "link shared" snackbar were removed.
- 503 `INVOICE_NOT_CONFIGURED` and 410 `INVOICE_EXPIRED` have honest UI states.
- Tests: `server/test/invoices.test.ts` 4/4, `test/invoice_screen_test.dart`
  2/2.

### 2 - reconciliation corrections are linked statements
- Migration `0020` adds `corrects_statement_id` and a required 10-300 character
  `correction_reason`, both immutable. The original must be closed and share
  source kind, source label, provider and currency.
- The import form offers closed statements, requires the reason, and both
  statements cross-link. The control room emits `statement.corrected`; audit
  records the same link. The original stays closed and unchanged.
- Errors: `STATEMENT_CORRECTION_ORIGINAL_OPEN` (409),
  `STATEMENT_CORRECTION_MISMATCH` (422), `CORRECTION_REASON_INVALID` (422).
- Tests: admin-web correction flow, original immutability and activity payload.

### 3 - localized scheduled app banners
- Migration `0021` adds `app_banners` and allows `app_banner:<uuid>` config keys.
  Banners use the existing versioned two-person proposal/approval flow; updates
  keep the id, removal is a proposal, and rollback restores or deletes.
- Validation: both messages 5-200 characters, severity
  `info|warning|critical`, window longer than zero and at most 90 days, start at
  most 180 days ahead, end in the future.
- `/config.banners` contains only windows open at request time. The Flutter
  shell re-checks the window, chooses English or Swahili, and schedules a
  rebuild for the next start/end boundary while it stays mounted.
- Admin: banner list with active/upcoming/ended state, same-id edit form,
  removal proposal, and human-readable before/after values.
- Tests: admin-web validation/approval/edit/upcoming/removal/rollback; Flutter
  `repositories_test.dart` parsing and `main_shell_screen_test.dart` language +
  expired filtering.

### 4 - stay signed in and biometric unlock (F5.3)
- `TokenStorage` now separates the access token from the rotating refresh token
  and clears both on sign-out. The refresh token is only read by the auth
  provider; it never enters app state, logs or analytics.
- `AuthNotifier.refreshAccessToken()` is single-flight: a burst of 401s shares
  one rotation, and the Dio `AuthInterceptor` replays each failed request once
  with the new access token. A rejected refresh clears both tokens; a network
  failure keeps them for the next launch. The refresh request itself is marked
  no-retry because its token is single-use.
- Splash restores the session after `/config`: rotate, then `GET /me`; a
  complete profile opens Home, `PROFILE_INCOMPLETE` opens KYC.
- `PinManager.ensureUnlocked` offers biometrics first when available, with the
  PIN dialog always as fallback. Security settings shows real availability and
  signs out through the auth provider. Android `USE_BIOMETRIC` and iOS
  `NSFaceIDUsageDescription` were added.
- Tests: `test/network_test.dart` concurrent-401 replay and no-token case;
  `test/auth_repository_test.dart` refresh request shape;
  `test/auth_provider_test.dart` restore, terminal failure, network failure and
  shared rotation.

### 5 - LISTEN/NOTIFY control-room transport
- `ActivityStream` keeps one pooled connection checked out while any SSE stream
  is open, runs `LISTEN admin_activity`, and polls immediately on a
  notification. The 2-second interval remains as the fallback; a failed
  listener reconnects after 5 seconds and polling continues.
- A notification that arrives during an in-flight poll schedules one more poll,
  so a burst is not missed until the next tick.
- Tests: a one-minute fallback interval still delivers immediately; a
  deliberately broken listener still delivers through polling.

### Verification
- Node: **121/121**, 21 suites, `tsc --noEmit` clean.
- Flutter: **231 passed, 1 skipped**, `flutter analyze` clean. The skip is the
  opt-in live sandbox contract test.
- Docs updated: API contract, admin implementation, this log and the master
  progress report.

Next: live provider/bank feeds, bank-side missing detection, fee-line matching,
bank balance matching, sanctions/watchlist and document capture. Nothing pushed.

---

## 2026-11-19 - Android biometric host and live sandbox contract rerun

- Android: `MainActivity` now extends `FlutterFragmentActivity`; `local_auth`
  does not work on a plain `FlutterActivity`. `compileSdk` is pinned to 35
  because the local-auth lifecycle plugin is compiled against it. `flutter
  build apk --debug` succeeded, so the fingerprint/Face ID host compiles.
- Real-device biometric verification is still not done: this machine has no
  attached Android device and Xcode is incomplete, so Face ID/iOS remains
  unverified. The web build has no biometric support and falls back to PIN.
- Live sandbox: an isolated copy of the sandbox SQLite database was started on
  port 8081 with `FACADE_SMS_DELIVERY=false` and `FACADE_DEV_OTP=true`.
  `LIVE_SANDBOX=1` passed end to end against it, including config/rates, OTP,
  KYC, profile, beneficiaries, quote, P2P collection, payout, history, timeline
  and the invoice fetched while the trade was active.
- The existing :8080 sandbox is configured for real SMS (`FACADE_SMS_DELIVERY=true`)
  and its local gateway is not running, so `/auth/otp/request` returns 503 and
  the live test cannot use that instance as-is. That is configuration, not a
  code failure; use an isolated dev-OTP instance for contract runs.
- No sandbox DB, GasLink key/route or protected SMS/AI file was modified.

Next: run the final repository/build suite on this follow-up commit, then take a
new snapshot.

---

## 2026-11-20 - biometric opt-in, customer session reset, worker heartbeat and containers

**Session rule followed**: no sandbox environment hardcoding, no invented
operational data in `lib/`, server is the source of truth, nothing written to
the sandbox database or protected SMS/AI files.

### Biometric unlock is now a real opt-in
- `BiometricPreference` stores the per-device choice in platform-secure storage.
  Default off. `PinManager.ensureUnlocked` only prompts for biometrics when a
  PIN exists, the preference is on, and the device reports an enrolled
  biometric. Denial/cancel falls back to the PIN dialog; no PIN means no gate.
- Security settings now has a real biometric switch, a "Test biometrics now"
  action, honest unavailable/no-enrolment text, and clears the preference when
  the PIN is turned off. Enabling requires a successful device check first.
- `test/biometric_unlock_test.dart` covers enabled success, denial fallback,
  no attempt before opt-in, the settings toggle, and the unavailable state.
- Android still uses `FlutterFragmentActivity` and `compileSdk 35`;
  `flutter build apk --debug` succeeds. A sideloadable build is at
  `~/Desktop/Projects/CrossPay/CrossPay-debug-biometrics-sandbox-2026-11-20.apk`
  (built with `API_BASE_URL=http://192.168.1.3:8080`; SHA-256
  `4095894f05a2aa1dbad7c98e1aa3f5c3ddec446b0cf0a31eb3d4d0dc60c38f00`).
- Real-device fingerprint/Face ID and iOS remain unverified here.

### Customer session reset
- Support Customer 360 shows active refresh-token sessions and families. A
  `support:write` operator can revoke all sessions for one customer with a
  5-300 character reason.
- Revocation updates only `refresh_tokens`, records the reason and counts in
  `admin_audit_log`, and emits a redacted `customer.sessions_revoked` activity
  event. KYC, trades, cases and money are untouched. Viewers are denied.
  Refresh rotation now also locks the user row first, so a concurrent refresh
  cannot insert a new token after the revocation sweep.
- Verified by a new admin-web test covering counts, validation, family
  revocation, another customer's untouched token, audit reason and redaction.

### Worker heartbeat and deployment scaffolding
- Migration `0022` adds `worker_heartbeats`. `runWorkerPass` records start,
  finish, duration and error count without changing the pass result. The admin
  overview shows the last pass age and raises warning/critical alerts for a
  missing or stale worker.
- The worker entrypoint moved to `src/worker-cli.ts` / `src/worker-main.ts` so
  the compiled image can run it without `tsx`.
- Added compiled `src/db/migrate-cli.ts` and
  `src/admin-web/create-admin-cli.ts` entrypoints.
- Added `server/Dockerfile`, `server/.dockerignore`, root `compose.yaml`
  (PostgreSQL 17, one-shot migrations, API, admin, worker, health checks) and
  `docs/DEPLOYMENT.md` with migration, admin creation, health and backup steps.
  Docker is not installed on this machine, so the YAML was syntax-checked and
  the compiled entrypoints exercised, but the containers were not run.

### Verification
- Node: **122/122**, 21 suites; typecheck clean; production build clean and the
  new compiled entrypoints present.
- Flutter: **236 passed, 1 skipped**; analyzer clean; debug APK built.
- Live sandbox contract from the previous run still passes against the isolated
  dev-OTP instance; the active :8080 real-SMS configuration was not changed.

Next: push the local branch to origin after the product owner's explicit
confirmation, then take the final snapshot.

---

## 2026-11-20 - operator runbook and compile-time API URL correction

- The served debug APK had been built without `--dart-define=API_BASE_URL`, so
  it could never pass splash regardless of the sandbox. It was rebuilt against
  `http://192.168.1.3:8080` (the current LAN sandbox facade), verified by
  searching the APK's `kernel_blob.bin` for the URL, and re-served under
  `CrossPay-debug-biometrics-sandbox-2026-11-20.apk`.
- Added `docs/RUNBOOK.md`: topology and port checks, first-run commands,
  sandbox real-SMS vs dev-OTP modes, OTP code retrieval, APK build/serve/install,
  biometric smoke test, database backup/restore, admin operations, incident
  playbook, snapshot/release procedure and documentation update rules.
- README, `docs/DEPLOYMENT.md` and the screenshot/APK instructions now link the
  runbook. The APK checksum changed to
  `4095894f05a2aa1dbad7c98e1aa3f5c3ddec446b0cf0a31eb3d4d0dc60c38f00`.
- No app or server behavior changed; this is documentation plus the rebuilt
  debug artifact.

---

## 2026-11-20 - dev-OTP APK so sign-in works for the biometric test

- The normal `:8080` sandbox is configured for real SMS. Its local gateway is not
  running, so OTP returns 503 even though config/rates load. For app sign-in, a
  dev-OTP facade was started on `:8081` using the same SQLite database and the
  same institution/account data, with workers disabled:
  `PORT=8081 FACADE_SMS_DELIVERY=false FACADE_DEV_OTP=true node -e "require('./server').start(8081,{startWorkers:false})"`.
- The debug APK was rebuilt with `API_BASE_URL=http://192.168.1.3:8081` and
  verified by reading `kernel_blob.bin`. Splash, OTP, KYC and the biometric
  settings can now all be exercised on a physical Android device.
- Final sideload artifact:
  `~/Desktop/Projects/CrossPay/CrossPay-debug-biometrics-devotp-2026-11-20.apk`
  (203 MB, SHA-256
  `878387bb88c168002cc6e91fd242f91da690df480a6a3947126c56bef944d23c`).
- The runbook now documents both OTP modes, retrieving the code from
  `/dashboard` or `/api/v1/sandbox/state`, and the fact that the API base URL is
  compile-time.
- No app/server code changed; no sandbox SQLite rows, GasLink keys/routes or
  protected SMS/AI files were modified.

---

## 2026-11-20 - lock vs sign-out, no OTP on every app open

- Split the two concepts the app previously conflated:
  - **Lock** hides the signed-in surface and asks for biometrics/PIN. The
    refresh token and session stay. The shell now auto-locks when the app is
    backgrounded, has a Locked screen with Unlock/Sign out, and Security has a
    **Lock app now** action wired through `appLockProvider`.
  - **Sign out** is a full logout: the app calls `POST /api/v1/auth/logout`,
    the server revokes the refresh-token family, then local tokens are cleared.
    OTP is required next time, by design.
- Added `POST /api/v1/auth/logout` (204, idempotent, family revocation) and an
  app-side best-effort call. The sandbox facade has no logout route yet; the app
  tolerates that and still clears the local session.
- Splash now reads whether a refresh token exists. While checking it shows a
  spinner instead of "Get started"; a returning user gets **Continue** (retry
  restore) and "Sign in with a code", while Get started is only shown when no
  stored session exists. A normal app restart restores silently and then asks
  for biometrics/PIN, not OTP.
- Documentation: API contract, decisions, runbook incident table and the
  biometric smoke test now describe lock vs sign-out and the OTP rule.

Next: rebuild the Android artifact, run the final suites and re-serve the APK.

---

## 2026-11-20 - one phone, one account; entry modes and switch account

- Confirmed the model: one phone number = one account. OTP signs in to an
  existing number or creates the account for a new number. There is no second
  account on the same phone and no separate registration identity.
- `POST /auth/otp/verify` now returns `isNewUser` (derived from the upsert), and
  the app uses it only for the “account created” / “welcome back” message.
- Splash now has **Sign in** and **Create account** instead of a single Get
  started. Both use the same phone → OTP path; phone entry copy and post-verify
  messaging follow the chosen mode. OTP screen has “Use a different number”.
- Security has **Switch account**: confirm, revoke the current refresh family,
  clear local tokens and the device PIN/biometric preference, then return to
  the start screen where Sign in is available. The locked screen now offers
  “Sign in with a different account” and does the same. Explicit Sign out also
  clears the local lock.
- Documented the agreed deleted-account policy: support/compliance only, soft
  delete, sessions revoked, phone reserved for retention, 30-day restore window,
  then compliance-approved reuse with fresh KYC.
- Added `docs/AUTH_FLOWS.md` with the full state/scenario table and linked it
  from README, DECISIONS, API contract and the runbook.

Verification pending: final Flutter/Node suites, web/APK rebuild and re-serve.

---

## 2026-11-20 - auth flow verification and rebuilt APK

- Final checks on the one-phone-one-account flow: Node **123/123** in 21 suites,
  typecheck/build clean; Flutter **237 passed, 1 skipped**, analyzer clean.
- Rebuilt the debug APK with the auth-flow changes and
  `API_BASE_URL=http://192.168.1.17:8081` (the Mac LAN address changed during
  the server restart). Final sideload artifact:
  `~/Desktop/Projects/CrossPay/CrossPay-debug-authflow-2026-11-20.apk`
  (203 MB, SHA-256
  `53eb0d4ffd0c155a869612bf46e2df30a0a2d64611b0e1e9f00ae51819811c47`).
- The served APK on the local file server was replaced with this build; the
  previous biometric/dev-OTP file is no longer served.
- Web release build refreshed on this commit: **Built build/web**.

---

## Report End - No fluff. Just facts.
