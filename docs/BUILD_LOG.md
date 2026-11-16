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

## 2026-11-16 - B4.4 liquidity providers and B4.5 Phase A admin

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

## Report End - No fluff. Just facts.
