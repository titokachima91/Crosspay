# CrossPay

Non-custodial cross-border transfers between East African mobile-money and bank
rails. The Flutter app displays server state and never holds customer cash; the
Node/Fastify API and PostgreSQL are the source of truth.

**Operator runbook: [`docs/RUNBOOK.md`](docs/RUNBOOK.md)** — start here for
ports, sandbox OTP modes, APK builds, failure recovery and database operations.

## Repository

| Path | What it is |
|---|---|
| `lib/`, `test/`, `preview/` | Flutter app, widget/unit tests and preview-only fixtures |
| `server/src/` | API, admin web portal, providers, ledger, matching and worker |
| `server/db/migrations/` | PostgreSQL schema (22 migrations) |
| `server/test/` | Node API, ledger, matching, admin, provider and worker tests |
| `docs/` | API contract, decisions, build log, admin, deployment and feature specs |
| `compose.yaml`, `server/Dockerfile` | Production-like container stack |

Simulated data lives only in `preview/` and in the separate Kachi sandbox. The
real app and API never invent providers, balances, screening results or payment
success.

## Local development

Prerequisites: Flutter 3.24+, Node 22+, and the repo's npm dependencies.

```bash
# API dependencies
cd server && npm ci

# Persistent local PostgreSQL (no Docker/system Postgres needed)
npm run dev:db          # port 55432; applies migrations and seed

# API and admin portal
npm run dev             # API on :3000
npm run admin:dev       # admin portal on :3001
npm run worker          # reconciliation worker

# Flutter
cd .. && flutter pub get && flutter run
```

`server/.env` is gitignored. Start from `server/.env.example`; `DATABASE_URL`
must point at the local cluster when using `dev:db`.

The first named admin:

```bash
cd server
npm run admin:create -- --email admin@example.com --name "Ada" --role superadmin
```

The command prints the TOTP secret and recovery codes once. Store them offline.

## Tests and builds

```bash
cd server
npm run typecheck
npm test                     # 125 tests, 21 suites
npm run build

cd ..
flutter analyze
flutter test                 # 237 passed, 1 skipped (opt-in live sandbox)
flutter build web --release -t preview/main.dart
flutter build apk --debug
```

The skipped test is the live sandbox contract. Run it against an isolated
dev-OTP sandbox:

```bash
LIVE_SANDBOX=1 LIVE_SANDBOX_URL=http://127.0.0.1:8081 \
LIVE_SANDBOX_KEY=<sandbox-crosspay-key> \
flutter test test/live_sandbox_test.dart
```

The sandbox needs `FACADE_SMS_DELIVERY=false FACADE_DEV_OTP=true` and a copied
SQLite database when the main instance is configured for real SMS.

## Android biometric smoke test

The sideload build is
`~/Desktop/Projects/CrossPay/CrossPay-debug-authflow-2026-11-20.apk`.
It was compiled with `API_BASE_URL=http://192.168.1.17:8081`, the dev-OTP sandbox
that shares the normal sandbox database. If the Mac's LAN address changes,
rebuild with the current address (see the runbook).

```bash
adb install -r ~/Desktop/Projects/CrossPay/CrossPay-debug-authflow-2026-11-20.apk
```

1. Sign in and open **Account → Security**.
2. Set a 4–6 digit PIN. Biometrics start off.
3. Enable **Biometric unlock**; the device prompt must succeed first.
4. Tap **Test biometrics now**.
5. Kill and reopen the app: the fingerprint/face prompt appears. Cancel it and
   the PIN dialog must appear instead.
6. Disable biometrics: the app must go straight to the PIN dialog.
7. Turn the PIN off: the app lock and biometric preference are cleared.

If sign-in stops at OTP, open `http://192.168.1.17:8081/dashboard` and read the
pending code under **OTP codes** (the runbook explains the key), or query
`/api/v1/sandbox/state` with `SANDBOX_API_KEY_CROSSPAY`.
If the device reports no enrolled biometric, the switch stays disabled with the
honest unavailable message. Real Face ID/iOS is not verified until Xcode is
installed.

## Security model

- Customer accounts belong to the PSP/bank; CrossPay does not hold customer
  cash. Partner accounts are settlement, clearing, trust and operating accounts.
- Access tokens are short-lived; rotating refresh tokens live only in Keychain
  or Android Keystore-backed storage. Refreshes are single-flight and never
  retried. Only one session is active per account: a new OTP sign-in revokes
  the old family and its access token with `SESSION_REVOKED`.
- The app lock is a local PIN with an optional biometric preference. Biometrics
  are off until the person enables them; the PIN is always the fallback.
  Locking (or backgrounding) keeps the session and unlocks with biometrics/PIN.
  Signing out revokes the refresh-token family and requires a new OTP.
- Admin access is named accounts with TOTP/recovery codes, CSRF, RBAC, audit and
  an append-only activity outbox. The portal never edits journals, marks money
  paid or reveals PII without a reason.
- Amounts are whole minor units and are never summed or compared across
  currencies.

## Deployment

See `docs/DEPLOYMENT.md` for the container stack, compiled migration and admin
entrypoints, health checks, worker heartbeat and backup/restore commands.

## Documentation

- `docs/RUNBOOK.md` — ports, sandbox OTP modes, builds, recovery and database ops
- `docs/AUTH_FLOWS.md` — one-phone-one-account, lock/sign-out/switch and deletion
- `docs/api_contract.md` — exact app/API shapes and error codes
- `docs/DECISIONS.md` — settled product and technical decisions
- `docs/BUILD_LOG.md` — append-only record of what was built and verified
- `MASTER_PROGRESS_REPORT.md` — current phase, snapshots and blockers
- `docs/ADMIN_WEB_IMPLEMENTATION.md` — admin portal and control room
- `docs/REVENUE_AND_BOOKKEEPING.md` — ledger and revenue rules
