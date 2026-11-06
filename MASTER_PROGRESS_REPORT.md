# CROSSPAY: MASTER PROGRESS REPORT

**Updated**: 2026-11-07
**Project**: CrossPay
**Package**: crosspay_app
**Environment**: macOS Monterey | Flutter 3.24.5 | Dart 3.5.4
**Progress**: 15 of 33 done (45%); F4.1 and F5.3 partially built (2026-11-06)

---

## PROJECT OVERVIEW

CrossPay is engineered as a non-custodial, server-driven cross-border payments engine. The app only displays state; it never holds customer funds. Escrow deposits flow to licensed partner bank/PSP omnibus trust accounts.

**Real App**: `flutter run -d chrome (+ --dart-define=API_BASE_URL=<address>)` - Only splash + phone screens work until a backend exists.

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
- [x] F1.2 Theme (Navy #1A237E, Emerald #00C853)
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
- [x] F3.5 Live escrow & queue tracker + support - **COMPLETE & DOCUMENTED**
- [x] F3.6 Digital invoice & share sheet - **COMPLETE & DOCUMENTED**

### F4 Ledger & Market
- [ ] F4.1 Searchable ledger & filters (+ ledger model/provider) - **partial (2026-11-06): history screen w/ search + status filter built; date-range filter, export, timeline, analytics remain** -> `FEATURE_SPEC/F4/F4.1.md`
- [ ] F4.2 Market depth & queue health

### F5 Profile & Security
- [ ] F5.1 Profile & limit bar
- [ ] F5.2 Saved recipients CRUD
- [ ] F5.3 Security: PIN/biometric lock, stay signed in, remember language - **partial (2026-11-06): PIN lock + app-shell gate + language selector built; biometrics, stay-signed-in, language persistence remain** -> `FEATURE_SPEC/F5/F5.3.md`

---

## PART 2: BACKEND (Node.js + TypeScript API)

### B1 Schema
- [ ] B1.1 schema.sql
- [ ] B1.2 Double-entry ledger
- [ ] B1.3 Quote expiry store (DB)

### B2 Trade API
- [ ] B2.1 Idempotency
- [ ] B2.2 /trade/quote
- [ ] B2.3 /trade/initiate
- [ ] B2.4 /payments/disburse

### B3 Payments
- [ ] B3.1 Inbound webhook
- [ ] B3.2 P2P queue
- [ ] B3.3 Refund worker

---

## PART 3: TESTING

- [x] Widget & unit suites - `flutter test` -> **169/169 passing** (2026-11-06)
- [ ] T1.1 End-to-end sandbox run
- [ ] T1.2 KYC/sanctions
- [ ] T1.3 Pilot

---

## FEATURE SPECIFICATION DOCUMENTATION

### Completed Specifications
- [x] `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker
- [x] `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet

### Active Specifications (partially built features)
- [ ] `FEATURE_SPEC/F4/F4.1.md` - Searchable Ledger & Filters (partial + implementation log)
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
8. Logo | Privacy policy text | Swahili review (sw.json, 169 keys)
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
- Logo letter mark | Ledger/Rates/Account tabs | Tracker destination (F3.5)

---

## BACKEND CONTRACT REQUIREMENTS

Backend MUST:
- Honor X-Idempotency-Key (repeated key returns original result, never collects twice)
- Error shape: {error: {code, message}}
- GET /config (+currency decimals, payout rail kind)
- /rates | POST /auth/otp/request|verify
- /auth/refresh | PUT /me/kyc | GET /me
- GET /trade/estimate | POST /trade/quote
- GET /beneficiaries | POST /beneficiaries/check
- POST /trade/initiate (+collection details)
- GET /trades/{id} | POST /trades/{id}/payment-claim | POST /trades/{id}/cancel
- Fee on top; refuse transactions until verified
- Never log request bodies
- Licensed partner for escrow

---

## IMPLEMENTATION STATUS SUMMARY

### Completed Features (15/33)
| Feature | Status | Documentation | Tests | Analysis |
|---------|--------|---------------|-------|----------|
| F3.3 | Complete | Complete | Passing | 0 issues |
| F3.4 | Complete | Complete | Passing | 0 issues |
| F3.5 | Complete | Complete | Passing | 0 issues |
| F3.6 | Complete | Complete | Passing | 0 issues |

### Partially Built (tracked under their real plan IDs, built 2026-11-06)
| Feature | Status | Documentation | Tests | Analysis |
|---------|--------|---------------|-------|----------|
| F4.1 | Partial - history search + status filter shipped | `FEATURE_SPEC/F4/F4.1.md` | Passing | 0 issues |
| F5.3 | Partial - PIN lock + language selector shipped | `FEATURE_SPEC/F5/F5.3.md` | Passing | 0 issues |

### Code Quality
- `dart analyze lib/ test/` → No issues found (verified 2026-11-07)
- `flutter test` → **169/169 all passing** (verified 2026-11-07)
- Payment notifier ignores late results once disposed (`_disposed` guards in `start`/`_poll`, 2026-11-07) - the fallback-timeout test exposed a poll landing on an already-disposed container
- Preview/fakes errors resolved

### Documentation Files
- `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker specification
- `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet specification
- `FEATURE_SPEC/F4/F4.1.md` - Searchable Ledger & Filters (partial + implementation log)
- `FEATURE_SPEC/F5/F5.3.md` - Security / language (partial + implementation log)

---

## CURRENT PHASE: F4 - LEDGER & MARKET

**F3 is closed at F3.6. F4 opens now, with part of F4.1 (and F5.3) already built.**

- **F4.1 (partial, built 2026-11-06):** transaction history screen (`/history`) with search + status filter, `trade_history_provider`, `getTrades()` in the trade repository, `ApiEndpoints.trades/tradeInvoice/tradeShare`. Remaining: date-range filter, CSV export, status timeline, analytics dashboard; backend `GET /trades` plus history/analytics/export endpoints. Spec: `FEATURE_SPEC/F4/F4.1.md`.
- **F4.2 (not started):** market depth & queue health.
- **F5.3 (partial, built early 2026-11-06):** PIN lock (`lib/core/security/pin_manager.dart`), app-shell PIN gate, language selector (`/language`), security settings (`/security`), Account tab hub. Remaining: `local_auth` biometrics, stay-signed-in / refresh-token rotation, language persistence, 3+ languages/RTL. Spec: `FEATURE_SPEC/F5/F5.3.md`.
- **Verified (2026-11-06):** `dart analyze lib/ test/` -> **No issues found**; `flutter test` -> **169/169 passing**; `flutter build web --release -t preview/main.dart` -> preview served HTTP 200 (port 8000).
- **Git:** pushed to `origin/main` (`github.com/titokachima91/Crosspay.git`) through `707b852`, plus this documentation commit.

### Provenance note (recorded 2026-11-07)

The 2026-11-06 commits labeled "F3.7.x" contain work now tracked under its real plan IDs: **F4.1 (partial)**, **F5.3 (partial)**, plus two kept extras (route comparison screen, Account tab hub). **"F3.7" was never in the plan - F3 ends at F3.6.** The `FEATURE_SPEC/F3/F3.7.md` file has been dismantled into `FEATURE_SPEC/F4/F4.1.md` and `FEATURE_SPEC/F5/F5.3.md`; its full original text remains recoverable in git history (commit `707b852`). This report is the plan of record.

### Kept extras (not in the plan, deliberately retained)

- Route comparison screen - `lib/features/transaction/screens/route_comparison_screen.dart`, route `/compare-routes`; reads live quotes from `quoteProvider` and shows an empty state (no hardcoded routes).
- Account tab hub - `lib/features/account/screens/account_tab_screen.dart`, 4th shell tab; hosts the entry points for F4.1 / F5.3.

### Backlog (not in the plan)

- `lib/core/network/environment_config.dart` (environment URLs + feature flags) - the earlier copy never compiled (undefined `_Instance` type in `FeatureFlags`) and was deleted; write fresh if/when a real-money release is scheduled. Not one of the 33 plan items.

---

## Report End - No fluff. Just facts.
