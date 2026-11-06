# CROSSPAY: MASTER PROGRESS REPORT

**Updated**: 2026-11-06
**Project**: CrossPay
**Package**: crosspay_app
**Environment**: macOS Monterey | Flutter 3.24.5 | Dart 3.5.4
**Progress**: 11 of 33 done (33%)

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
- [ ] F4.1 Searchable ledger & filters (+ ledger model/provider)
- [ ] F4.2 Market depth & queue health

### F5 Profile & Security
- [ ] F5.1 Profile & limit bar
- [ ] F5.2 Saved recipients CRUD
- [ ] F5.3 Security: PIN/biometric lock, stay signed in, remember language

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

- [x] F3.3 Complete - COMPLETE & VERIFIED
- [x] F3.4 Complete - COMPLETE & VERIFIED
- [x] F3.5 Complete - COMPLETE & DOCUMENTED
- [x] F3.6 Complete - COMPLETE & DOCUMENTED

- [ ] T1.1 End-to-end sandbox run
- [ ] T1.2 KYC/sanctions
- [ ] T1.3 Pilot

---

## FEATURE SPECIFICATION DOCUMENTATION

### Completed Specifications
- [x] `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker
- [x] `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet

### Pending Specifications
- [ ] `FEATURE_SPEC/F3/F3.7.md` - Next feature phase

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

### Completed Features (11/33)
| Feature | Status | Documentation | Tests | Analysis |
|---------|--------|---------------|-------|----------|
| F3.3 | Complete | Complete | Passing | 0 issues |
| F3.4 | Complete | Complete | Passing | 0 issues |
| F3.5 | Complete | Complete | Passing | 0 issues |
| F3.6 | Complete | Complete | Passing | 0 issues |

### Code Quality
- `dart analyze lib/ test/` → No issues found (verified 2026-11-06)
- `flutter test` → **169/169 all passing** (verified 2026-11-06)
- Preview/fakes errors resolved

### Documentation Files
- `FEATURE_SPEC/F3/F3.5.md` - Live Escrow & Queue Tracker specification
- `FEATURE_SPEC/F3/F3.6.md` - Digital Invoice & Share Sheet specification
- `FEATURE_SPEC/F3/F3.7.md` - Advanced Features specification (incl. implementation log, Steps 1-7)

---

## CURRENT PHASE: F3.7 IMPLEMENTATION (in progress)

**Core implemented & verified; production config / export / biometrics remain.**

- **Done:** route comparison (`/compare-routes`), transaction history (`/history`, in `lib/features/ledger/`), security settings (`/security`), language selector (`/language`, en/sw per shipped localization), Account tab hub as 4th shell tab, PIN gate with fail-open on storage errors — all routes registered in `app.dart`.
- **Verified (2026-11-06):** `dart analyze lib/ test/` → **No issues found**; `flutter test` → **169/169 passing**. The PIN-gate test hang was root-caused (secure-storage MethodChannel never completes under `testWidgets`) and fixed test-side via `FlutterSecureStorage.setMockInitialValues({})` — full diagnosis in `F3.7.md` Step 7. Also fixed: `setLocale` → `setLanguage`, shell test expectation. `GATE-DEBUG` probes removed.
- **Build/preview:** `flutter build web --release -t preview/main.dart` → served HTTP 200 on port 8000.
- **Remaining:** F3.7.5 production config (`environment_config.dart` re-create — old `Env`/`FeatureFlags` copy had invalid syntax and was deleted), analytics CSV export, `local_auth` biometric wiring, 3+ languages/RTL, planned test files (`route_selection_test`, `security_test`, `analytics_test`), backend `GET /trades` for real history data.
- **Git:** local commits through `c236a85` + this session's commit; **GitHub remote still missing** — Tito to supply repo URL + auth, then push.

---

## Report End - No fluff. Just facts.
