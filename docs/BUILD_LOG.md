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

### Still open (not silently claimed as done)
- B2.3 initiation/collection and B2.4 payouts/refunds.
- Market depth is not proxied by CrossPay; the sandbox still serves it.
- Real pricing and approved tier limits are Product/Finance decisions.
- No push was made; the branch stays local until the product owner confirms.

---

## Report End - No fluff. Just facts.
