# CrossPay API

Node.js + TypeScript service for CrossPay.

- **B1** — PostgreSQL schema, migrations, seed, encryption, idempotency,
  quote lifecycle and double-entry ledger. Built and verified 2026-11-14.
- **B2.0** — HTTP bootstrap: `/config`, OTP sign-in, refresh rotation, `/me`,
  KYC submission and saved-recipient CRUD. Built and verified 2026-11-15.
- **B2.2** — rates, estimate and durable quotes. Built 2026-11-15.
- **B2.3** — trade initiation, collection lifecycle and trade reads. Built
  2026-11-16.
- **B2.4** — payouts, refunds and signed provider callbacks. Built 2026-11-16.
- **B4** — P2P matching v1: FIFO full-fill, two-leg payout saga, compensation
  and corridor controls. Built 2026-11-16.

The Flutter app remains the only client contract. `docs/api_contract.md` is the
contract of record. The B1 plan is `docs/B1_DATABASE_PLAN.md`; the build evidence
is `docs/B1_IMPLEMENTATION.md`, `docs/B2_IMPLEMENTATION.md`,
`docs/B2_2_IMPLEMENTATION.md`, `docs/B2_3_B2_4_IMPLEMENTATION.md` and
`docs/B4_MATCHING_IMPLEMENTATION.md`.

---

## Requirements

- Node.js 22 or newer (the current development machine uses Node 24).
- PostgreSQL 15 or newer. Production: Supabase or any managed PostgreSQL.
- No Redis is required; quote expiry, rate limits and idempotency live in
  PostgreSQL.

## Layout

```
server/
  db/
    migrations/        Forward-only SQL migrations (source of truth)
    seed/              Idempotent reference data
    ERD.md             Entity relationship diagram
    RUNBOOK.md         Migration, backup and incident runbook
  scripts/
    migrate.ts         Apply pending migrations
    seed.ts            Apply reference data
    verify.ts          Post-deployment schema and config check
    verify-local.ts    Fresh ephemeral database check
  src/
    crypto.ts          AES-256-GCM and HMAC helpers
    idempotency.ts     Replay-safe idempotency primitives
    quotes.ts          Single-use quote consumption and expiry
    ledger.ts          Balanced journal posting and reversals
    auth/              OTP and refresh-token families
    http/              Fastify server, auth, routes and error mapping
    providers/         SMS, pricing and payment adapter boundaries
    services/          Rate limiting and user/limit resolution
    db/                Pool, migration runner, seed runner
    repositories/      Read models such as GET /config
  test/                Integration tests against embedded PostgreSQL 17
```

## First run

```sh
cd server
cp .env.example .env
# edit DATABASE_URL, DATA_ENCRYPTION_KEY and JWT_SECRET
npm ci
npm run migrate
npm run seed
npm run verify
npm run dev
```

Generate both 32-byte keys with:

```sh
openssl rand -base64 32
```

Keys belong in the hosting secret manager. They are never written to the
database, a migration or a log line.

## HTTP surface (B2.0)

| Method | Path | Status |
|---|---|---|
| GET | `/health` | Live database check |
| GET | `/api/v1/config` | Complete, server-driven five lists |
| POST | `/api/v1/auth/otp/request` | Complete; SMS provider must be configured |
| POST | `/api/v1/auth/otp/verify` | Complete; issues access + rotating refresh tokens |
| POST | `/api/v1/auth/refresh` | Complete; reuse revokes the token family |
| GET | `/api/v1/me` | Complete after KYC |
| PUT | `/api/v1/me/kyc` | Complete; stores encrypted identifier, status `pending` |
| GET/POST | `/api/v1/beneficiaries` | Complete, with idempotent writes |
| PATCH/DELETE | `/api/v1/beneficiaries/{id}` | Complete, ownership-checked |
| POST | `/api/v1/beneficiaries/check` | `503 NAME_CHECK_NOT_CONFIGURED` |
| GET | `/api/v1/rates` | Provider rates; `503 PRICING_NOT_CONFIGURED` without one |
| GET | `/api/v1/trade/estimate` | Indicative estimate, no lock |
| POST | `/api/v1/trade/quote` | Durable quote + route snapshot |
| POST | `/api/v1/trade/initiate` | Consumes the quote and starts one collection |
| GET | `/api/v1/trades` | Signed-in user's trades |
| GET | `/api/v1/trades/{id}` | Trade detail; the app's polling target |
| GET | `/api/v1/trades/{id}/history` | Immutable status timeline |
| GET | `/api/v1/trades/analytics` | Server-calculated completed-trade totals |
| GET | `/api/v1/trades/export` | Short-lived server-built CSV link |
| GET | `/api/v1/market/depth` | Real funded-queue depth per enabled corridor |
| POST | `/api/v1/trades/{id}/payment-claim` | Re-checks the provider |
| POST | `/api/v1/trades/{id}/cancel` | Cancels a pending deposit |
| POST | `/api/v1/trades/{id}/disburse` | Starts/resumes a payout |
| POST | `/api/v1/trades/{id}/refund` | Provider-confirmed full refund |
| POST | `/api/v1/trades/{id}/match` | One FIFO P2P match attempt |
| POST | `/api/v1/matches/{id}/disburse` | Pays/resumes both match legs |
| POST | `/api/v1/webhooks/payments/{provider}` | Signed provider callback |
| GET | `/api/v1/trades/export/download?token=...` | Public one-time CSV download |
| GET | `/api/v1/market/depth` | `503 MARKET_DATA_NOT_CONFIGURED` |

Every response error uses `{ "error": { "code": "...", "message": "..." } }`.
Protected routes require `Authorization: Bearer <accessToken>`. The public
routes are `/health`, `/config`, `/rates`, the OTP endpoints, `/auth/refresh`
and the provider webhook prefix `/api/v1/webhooks/payments/` (HMAC-authenticated).

`SMS_NOT_CONFIGURED` is returned until a real SMS partner is connected. This is
deliberate: the server never pretends to send a code. Tests inject a capturing
SMS transport through `buildServer()`.

## Verification

```sh
npm run typecheck
npm test
npm run verify:local
```

`npm test` starts an ephemeral PostgreSQL 17 cluster with `embedded-postgres`,
applies every migration and the seed, then exercises the schema, quote
lifecycle, trade timeline, idempotency race, ledger balance rules, append-only
guards, encryption, OTP limits, refresh rotation, the HTTP bootstrap,
collections, payouts, refunds, signed callbacks, P2P matching, market depth,
analytics, CSV export and the reconciliation worker.
**88 tests pass.** No Docker or local PostgreSQL installation is required.

Live provider smokes (with the sandbox running):

```sh
SANDBOX_API_KEY_CROSSPAY=<key> npm run smoke:b2.3
SANDBOX_API_KEY_CROSSPAY=<key> npm run smoke:b2.4
SANDBOX_API_KEY_CROSSPAY=<key> npm run smoke:webhooks
SANDBOX_API_KEY_CROSSPAY=<key> npm run smoke:b4
```

Reconciliation worker:

```sh
WORKER_ONCE=true npm run worker   # one pass
npm run worker                    # every WORKER_INTERVAL_SECONDS
```

`npm run verify` is for a real database. It checks migration state, the five
`/config` lists, payout-rail kinds, seeded rows and ledger balance.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string for migrations/API |
| `DATABASE_SSL` | no | `true` enables TLS with the managed provider |
| `DATA_ENCRYPTION_KEY` | yes | 32 random bytes, base64; application-level encryption |
| `JWT_SECRET` | yes | 32 random bytes, base64; access-token signing |
| `KYC_RETENTION_DAYS` | no | Provisional retention, default 2555 days |
| `LIMIT_TIMEZONE` | no | Provisional daily-limit boundary, default `UTC` |
| `IDEMPOTENCY_TTL_SECONDS` | no | Idempotency retention, default 86400 seconds |
| `ACCESS_TOKEN_TTL_SECONDS` | no | Access-token lifetime, default 900 seconds |
| `REFRESH_TOKEN_TTL_SECONDS` | no | Refresh lifetime, default 30 days |
| `PRICING_PROVIDER` | no | `disabled` (default) or `sandbox` |
| `PAYMENT_PROVIDER` | no | `disabled` (default) or `sandbox` |
| `SANDBOX_PAYMENTS_URL` / `KEY` | for sandbox | Sandbox provider primitives |
| `COLLECTION_PUSH_TIMEOUT_SECONDS` | no | Manual fallback delay, default 120 |
| `COLLECTION_POLL_INTERVAL_SECONDS` | no | App polling hint, default 5 |
| `PAYMENT_CALLBACK_URL` | no | Public URL sent to the provider |
| `PAYMENT_WEBHOOK_SECRET` | for webhooks | Shared HMAC secret |
| `PAYMENT_WEBHOOK_MAX_SKEW_SECONDS` | no | Callback timestamp tolerance, default 300 |
| `P2P_ENABLED` | no | Matching kill switch, default `false`; corridors live in `p2p_corridors` |
| `PUBLIC_API_URL` | for export | Absolute public origin used in export links |
| `WORKER_INTERVAL_SECONDS` | no | Worker pass interval, default 30 |
| `WORKER_ONCE` | no | `true` runs one pass and exits |
| `PORT` / `HOST` | no | HTTP listener, default `3000` / `0.0.0.0` |
| `LOG_LEVEL` | no | Pino level, default `info` |
| `CORS_ORIGINS` | no | Comma-separated web origins; empty for native-only |

## Deliberate data decisions

- **No support details are seeded.** There is no real support desk yet; the app
  must show "support options are not available" rather than a placeholder.
- **No daily limits are seeded.** `/me` reports `dailyLimitMinor: 0` until
  Product/Finance inserts an approved `tier_limits` row. The server never
  invents a limit.
- **No corridor rates or market depth are seeded.** The pricing endpoints return
  `503` until a source is connected.
- **KYC submissions are manual-review pending.** No KYC provider is connected;
  the server stores the encrypted identifier and returns `pending`.
- **Ledger accounts are provisional.** The chart is seeded for every active
  currency but marked `is_provisional = true` until Finance and Legal approve it.
- **Only real reference names are used.** Countries, currencies, carriers and
  payout rails are public data, not fake operational values.

## Security rules

- `lib/` and `server/` never share simulated data. Preview data stays in
  `preview/` only.
- KYC identifiers and recipient account numbers are encrypted with AES-256-GCM
  before they reach PostgreSQL. Lookups use HMAC-SHA-256 hashes.
- OTP codes and refresh tokens are stored as hashes only.
- Access tokens are short-lived HS256 JWTs. Refresh tokens rotate; reuse revokes
  the family.
- OTP request/verify are rate-limited by phone **and** by source IP using the
  database, so multiple API instances share the limit.
- The API must use a least-privilege database role. The migration role is
  separate. Ledger and timeline tables reject updates and deletes at the
  database boundary.
- Request bodies containing personal data must never be logged. The Fastify
  logger redacts `Authorization` and `X-Idempotency-Key`. No route logs a body.
- The app never connects directly to PostgreSQL. Supabase is the database host,
  not a public data API.

## Next step

1. Add liquidity-provider standing orders and the ops/dashboard surface
   (B4.4/B4.5).
2. Connect approved bank payout rails and name-check/KYC adapters.
3. Add invoice/share handlers; analytics and CSV export are live.
4. Replace the sandbox adapter with approved real providers when contracts
   exist.
