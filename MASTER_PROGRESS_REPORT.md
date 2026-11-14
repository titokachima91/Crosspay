# CROSSPAY: MASTER PROGRESS REPORT

**Updated**: 2026-11-15
**Project**: CrossPay
**Package**: crosspay_app
**Environment**: macOS Monterey | Flutter 3.24.5 | Dart 3.5.4 | Node 24 | PostgreSQL 17
**Progress**: 36 of 48 tracked items done (75%); B1 data foundation complete; B2.0 bootstrap built; pricing/SMS/provider integrations pending

---

## PROJECT OVERVIEW

CrossPay is engineered as a non-custodial, server-driven cross-border payments engine. The app only displays state; it never holds customer funds. Escrow deposits flow to licensed partner bank/PSP omnibus trust accounts.

**Real App**: `flutter run -d chrome (+ --dart-define=API_BASE_URL=<address>)` - The API now serves `/config`, OTP (when an SMS partner is configured), `/me`, KYC and recipients. Rates, market depth and trading return honest "not connected" states until their providers exist.

**Preview**: `flutter run -d chrome -t preview/main.dart` - Simulated data, code 1234

**Phone**: Preview APK for demos: `flutter build apk --debug -t preview/main.dart`

---

## CORE PRINCIPLES

1. No wallet, no stored balance - receive = payout to mobile money/bank
2. No mocks, nothing hardcoded in lib/ - data and rules come from the server
3. Simulated data lives ONLY in preview/
4. Money = whole numbers in smallest unit (Currency.decimals from server)
5. Server calculates, app displays
6. Unconnected pieces say so plainly ("unavailable", "not connected")
7. Screens verified by widget tests and walkable in preview app
8. Identity data (ID/TIN) never stored, kept in state or logged on device
9. Safeguard claims shown only when server confirms them
10. Recipient checks never reveal registered name; one idempotency key per attempt
11. Only the server decides that a payment arrived; the app only reads the status

---

## PART 1: FRONTEND (FLUTTER / RIVERPOD)

### F1 Core
- [x] F1.1 Scaffold & directory tree
- [x] F1.2 Theme (Navy #1A237E, Emerald #00C853; light/dark/system, remembered)
- [x] F1.3 Localization engine (en | sw)
- [x] F1.4 Riverpod state (auth, quote, trade, rates, config)
- [x] F1.5 Network client (Dio, JWT, retry)

### F2 Auth & Onboarding
- [x] F2.1 Splash & language switcher (+ /config and /rates)
- [x] F2.2 Phone entry & carrier suggestion
- [x] F2.3 SMS OTP verification grid (+ secure token storage)
- [x] F2.4 Identity & KYC (personal + business)
- [ ] P1 Preview app (extra)

### F3 Transaction Engine
- [x] F3.1 Home dashboard & converter + 4-tab navigation
- [x] F3.2 Route selection & rate lock (fee on top)
- [x] F3.3 Recipient details & name check - **COMPLETE & VERIFIED**
- [x] F3.4 Payment prompt & manual fallback - **COMPLETE & VERIFIED**
- [x] F3.5 Live escrow & queue tracker + support - **COMPLETE (support channels server-driven; in-app messaging pending)**
- [x] F3.6 Digital invoice & share sheet - **COMPLETE & DOCUMENTED**

### F4 Ledger & Market
- [x] F4.1 Searchable ledger, status timeline, CSV export, analytics - **done (frontend)** -> `FEATURE_SPEC/F4/F4.1.md`
- [x] F4.2 Market depth & queue health - **done (frontend)** -> `FEATURE_SPEC/F4/F4.2.md`

### F5 Profile & Security
- [x] F5.1 Profile & limit bar - **done (frontend)** -> `FEATURE_SPEC/F5/F5.1.md`
- [x] F5.2 Saved recipients CRUD - **done (frontend)** -> `FEATURE_SPEC/F5/F5.2.md`
- [ ] F5.3 Security: PIN/biometric lock, stay signed in, remember language - **partial: PIN lock, app-shell gate, language persistence and theme mode shipped; biometrics present but not wired; stay-signed-in blocked on `POST /auth/refresh`** -> `FEATURE_SPEC/F5/F5.3.md`

---

## PART 2: BACKEND (Node.js + TypeScript API)

### B1 Database foundation (plan: `docs/B1_DATABASE_PLAN.md`)
- [x] B1.0 Conventions and contract reconciliation
- [x] B1.1 Identity, access and reference data
- [x] B1.2 Recipients
- [x] B1.3 Quotes, quote routes and trades
- [x] B1.4 Idempotency and concurrency
- [x] B1.5 Double-entry ledger (structure verified; chart provisional)
- [x] B1.6 Financial operations scaffolding
- [x] B1.7 Migrations, seed, ERD and verification

**B1 status**: built and tested 2026-11-14 in `server/` -> `docs/B1_IMPLEMENTATION.md`.
31 integration tests pass against ephemeral PostgreSQL 17; `dart analyze` and
the Flutter suite are unchanged. Finance/Legal sign-off of the chart of accounts
and escrow treatment remains the only open B1 gate.

### B2 API (plan: `docs/B2_IMPLEMENTATION.md`)
- [x] B2.0 Bootstrap: `/config`, OTP, refresh rotation, `/me`, KYC, recipients
- [x] B2.1 Idempotency: database primitive plus HTTP wrapper on every recipient write
- [ ] B2.2 `/trade/quote` — blocked on an approved pricing source
- [ ] B2.3 `/trade/initiate` — blocked on pricing and payout-provider contracts
- [ ] B2.4 `/payments/disburse` — blocked on the payout provider

**B2.0 status**: built and tested 2026-11-15 in `server/src/http/`.
36 integration tests pass. Rates, market depth, trade and name-check endpoints
return honest `503` states; no price or queue number is invented. SMS delivery
requires a real partner behind `SmsSender`.

### B3 Payments
- [ ] B3.1 Inbound webhook
- [ ] B3.2 P2P queue
- [ ] B3.3 Refund worker

---

## PART 3: TESTING

- [x] Widget & unit suites - `flutter test` -> **218/218 passing** (2026-11-10)
- [ ] T1.1 End-to-end sandbox run
- [ ] T1.2 KYC/sanctions
- [ ] T1.3 Pilot

---

## FEATURE SPECIFICATION DOCUMENTATION

### Completed Specifications
- [x] `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker + support
- [x] `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet
- [x] `FEATURE_SPEC/F4/F4.1.md` - Searchable Ledger, Timeline, CSV Export & Analytics
- [x] `FEATURE_SPEC/F4/F4.2.md` - Market Depth & Queue Health
- [x] `FEATURE_SPEC/F5/F5.1.md` - Profile & Limit Bar
- [x] `FEATURE_SPEC/F5/F5.2.md` - Saved Recipients CRUD

### Active Specifications (partially built features)
- [ ] `FEATURE_SPEC/F5/F5.3.md` - Security / language (partial + implementation log)

---

## HOSTING PLAN

**Stage 0 now**: Your Mac, $0
**Stage 1**: Partner sandboxes - Render ~$7-14 + free Supabase
**Stage 2**: Real-money pilot: Render + Supabase Pro ($25) + domain, ~$40-50/month

NOT Vercel for the API (Hobby is non-commercial; serverless fits workers poorly)
Vercel only for future website/admin dashboard

Private GitHub repo; secrets only in host settings; staging separate from production

---

## DECISIONS (SETTLED)

- Fee on top | No float balance ("Available today")
- Backend stack | Android min API 23
- Stay signed in behind PIN/biometric | Language remembered (F5.3)
- Receive = payout, no wallet | Limits/tiers from server
- Simulated data only in preview/ | Converter figures from server (GET estimate)
- Currency decimals from server | Bell omitted until notifications exist
- Route cards: You pay / Recipient gets | Safeguard only when confirmed
- Expiry offers new rate | New quote per visit + server clock
- Recipient check: match-only answer
- Authorize allowed on match / blocked on mismatch or not found
- Allowed with warning when unverifiable
- One idempotency key per authorization attempt
- Lock countdown also on recipient check screen

---

## DECISIONS (YOURS - Cannot be done by AI)

1. Lawyer before public launch (incl. where ID data may be stored)
2. Approval of safeguard wording
3. Whether payouts to unverified names are acceptable
4. Wording "if you were charged, contact support"
5. Final name + domain/trademark
6. Partner conversations (SMS, mobile money aggregator, licensed bank/PSP)
7. Escrow partner | Name-lookup access | Payment collection callbacks
8. Logo | Privacy policy text | Swahili review (`sw.json`, 306 keys, parity checked 2026-11-10)
9. Decide the FX spread that covers the rate lock

---

## ANDROID BUILD

- Debug APK builds with JDK 17
- Minimum API 23
- JDK dir: `/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home`

---

## BLUEPRINT NOTES

### lib/ Structure
- repositories/ (config, rates, auth, trade, profile, beneficiary, status_parser)
- providers/ (profile, beneficiaries, estimate, send_check, recipient_check, authorize_check, payment)
- features/shell/ | widgets (status_badge, persistent_bottom_nav)
- core/utils | transaction widgets (route_option_card, fee_breakdown_card, rate_lock_pill)
- screens (beneficiary_input_screen, payment_prompt_screen)

### Key Types
- TradeStatus.cancelled | CollectionInstructions | ManualPayment | InitiatedTrade

### LATER TIDY
- route_selection_screen still has its own private lock pill; switch to shared RateLockPill when next touched

### TEMPORARY
- Logo letter mark (real asset pending)

---

## BACKEND CONTRACT REQUIREMENTS

Backend MUST:
- Honor X-Idempotency-Key (repeated key returns original result, never collects twice)
- Error shape: {error: {code, message}}
- GET /config (+currency decimals, payout rail kind, optional `support` block)
- /rates | POST /auth/otp/request|verify
- /auth/refresh | PUT /me/kyc | GET /me
- GET /trade/estimate | POST /trade/quote
- GET /beneficiaries | POST /beneficiaries/check
- POST /trade/initiate (+collection details)
- GET /trades | GET /trades/{id} | GET /trades/{id}/history
- POST /trades/{id}/payment-claim | POST /trades/{id}/cancel
- GET /trades/analytics | GET /trades/export
- Fee on top; refuse transactions until verified
- Never log request bodies
- Licensed partner for escrow

---

## IMPLEMENTATION STATUS SUMMARY

### Completed Features (19/33)
| Feature | Status | Documentation | Tests | Analysis |
|---------|--------|---------------|-------|----------|
| F3.3 | Complete | Complete | Passing | 0 issues |
| F3.4 | Complete | Complete | Passing | 0 issues |
| F3.5 | Frontend complete; support channels server-driven | `FEATURE_SPEC/F3/F3.5.md` | Passing | 0 issues |
| F3.6 | Complete | Complete | Passing | 0 issues |
| F4.1 | Done (frontend) - history, timeline, CSV export, analytics | `FEATURE_SPEC/F4/F4.1.md` | Passing | 0 issues |
| F4.2 | Done (frontend) - market depth & queue health | `FEATURE_SPEC/F4/F4.2.md` | Passing | 0 issues |
| F5.1 | Done (frontend) - profile & limit bar | `FEATURE_SPEC/F5/F5.1.md` | Passing | 0 issues |
| F5.2 | Done (frontend) - saved recipients CRUD | `FEATURE_SPEC/F5/F5.2.md` | Passing | 0 issues |

### Partially Built (tracked under their real plan IDs)
| Feature | Status | Documentation | Tests | Analysis |
|---------|--------|---------------|-------|----------|
| F5.3 | Partial - PIN lock, language persistence, theme mode, `/settings` hub; biometrics not wired | `FEATURE_SPEC/F5/F5.3.md` | Passing | 0 issues |

### Code Quality
- `dart analyze lib/ test/ preview/` -> No issues found (verified 2026-11-10)
- `flutter test` -> **218/218 all passing** (verified 2026-11-10); targeted tracker rerun after the final pinned-bar layout -> **3/3 passing**
- `flutter build web --release -t preview/main.dart` -> **Built build/web** (verified 2026-11-10)
- Every feature screen reads its colours from `Theme.of(context).colorScheme`; only brand/status colours and the QR module paint are fixed (2026-11-10 sweep)
- Payment notifier ignores late results once disposed (`_disposed` guards in `start`/`_poll`, 2026-11-07)
- Payment provider tests wait on state, not on fixed timers (`_waitFor`, 2026-11-10)

### Documentation Files
- `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker + support
- `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet
- `FEATURE_SPEC/F4/F4.1.md` - Searchable Ledger, Timeline, Export & Analytics
- `FEATURE_SPEC/F4/F4.2.md` - Market Depth & Queue Health
- `FEATURE_SPEC/F5/F5.1.md` - Profile & Limit Bar
- `FEATURE_SPEC/F5/F5.2.md` - Saved Recipients CRUD
- `FEATURE_SPEC/F5/F5.3.md` - Security / language (partial + implementation log)
- `FEATURE_SPEC/INDEX.md` - plan ID -> spec -> real state
- `docs/api_contract.md` - server contract
- `docs/BUILD_LOG.md` - append-only build history

---

## CURRENT PHASE: PART 2 - BACKEND

**The frontend build is complete for every plan item except F5.3, which remains
partial by design** (PIN, language and theme shipped; biometrics and
refresh-token stay-signed-in are still open). The next increment is the backend
(PART 2). A backend plan will be audited against `docs/api_contract.md` and the
existing frontend expectations before implementation. No backend exists in this
repository yet.

Frontend state on 2026-11-10:

- F3.5 tracker and support are complete on the frontend. Support channels appear
  only when the server publishes `/config.support`; in-app support messaging is
  not connected.
- F4.1 history, timeline, CSV export and analytics are built; F4.2 market depth
  is built. Every screen renders an honest "not connected" state until its
  endpoint exists.
- F5.1 profile and F5.2 saved recipients are built. F5.3 has PIN lock, language
  persistence and theme mode; biometrics and stay-signed-in remain blocked.
- Known follow-up: the status timeline presentation is functional but not final;
  the product owner flagged it on 2026-11-10 for a later pass.
- Verified: `dart analyze lib/ test/ preview/` -> **No issues found**;
  `flutter test -j 4` -> **218/218 passing**;
  `flutter build web --release -t preview/main.dart` -> **Built build/web**.
- Git: branch `fix/theme-system` is local; nothing has been pushed. See
  `git log` for the exact commit list.

### Provenance note (recorded 2026-11-07)

The 2026-11-06 commits labeled "F3.7.x" contain work now tracked under its real plan IDs: **F4.1 (partial)**, **F5.3 (partial)**, plus two kept extras (route comparison screen, Account tab hub). **"F3.7" was never in the plan - F3 ends at F3.6.** The `FEATURE_SPEC/F3/F3.7.md` file has been dismantled into `FEATURE_SPEC/F4/F4.1.md` and `FEATURE_SPEC/F5/F5.3.md`; its full original text remains recoverable in git history (commit `707b852`). This report is the plan of record.

### Kept extras (not in the plan, deliberately retained)

- Route comparison screen - `lib/features/transaction/screens/route_comparison_screen.dart`, route `/compare-routes`; reads live quotes from `quoteProvider` and shows an empty state (no hardcoded routes).
- Account tab hub - `lib/features/account/screens/account_tab_screen.dart`, 4th shell tab; hosts the entry points for F4.1 / F5.3.

### Backlog (not in the plan)

- `lib/core/network/environment_config.dart` (environment URLs + feature flags) - the earlier copy never compiled (undefined `_Instance` type in `FeatureFlags`) and was deleted; write fresh if/when a real-money release is scheduled. Not one of the 33 plan items.

---

## Report End - No fluff. Just facts.
