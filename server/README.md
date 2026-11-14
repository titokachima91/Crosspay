# CrossPay API — B1 data foundation

Node.js + TypeScript service for CrossPay. B1 delivers the PostgreSQL schema,
migrations, seed data, encryption helpers, idempotency primitives, quote
lifecycle and the double-entry ledger. It does **not** expose HTTP endpoints
yet; that is B2.

The Flutter app remains the only client contract. `docs/api_contract.md` is the
contract of record and `docs/B1_DATABASE_PLAN.md` is the approved build plan.

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
  src/
    crypto.ts          AES-256-GCM and HMAC helpers
    idempotency.ts     Replay-safe idempotency primitives
    quotes.ts          Single-use quote consumption and expiry
    ledger.ts          Balanced journal posting and reversals
    db/                Pool, migration runner, seed runner
    repositories/      Read models such as GET /config
  test/                Integration tests against embedded PostgreSQL 17
```

## First run

```sh
cd server
cp .env.example .env
# edit DATABASE_URL and DATA_ENCRYPTION_KEY
npm ci
npm run migrate
npm run seed
npm run verify
```

Generate the encryption key with:

```sh
openssl rand -base64 32
```

The key belongs in the hosting secret manager. It is never written to the
database, a migration or a log line.

## Verification

```sh
npm run typecheck
npm test
```

`npm test` starts an ephemeral PostgreSQL 17 cluster with `embedded-postgres`,
applies every migration and the seed, then exercises the schema, quote
lifecycle, trade timeline, idempotency race, ledger balance rules, append-only
guards and encryption. No Docker or local PostgreSQL installation is required.

`npm run verify` is for a real database. It checks migration state, the five
`/config` lists, payout-rail kinds, seeded rows and ledger balance.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string for migrations/API |
| `DATABASE_SSL` | no | `true` enables TLS with the managed provider |
| `DATA_ENCRYPTION_KEY` | yes | 32 random bytes, base64; application-level encryption |
| `KYC_RETENTION_DAYS` | no | Provisional retention, default 2555 days |
| `LIMIT_TIMEZONE` | no | Provisional daily-limit boundary, default `UTC` |
| `IDEMPOTENCY_TTL_SECONDS` | no | Idempotency retention, default 86400 seconds |

## Deliberate data decisions

- **No support details are seeded.** There is no real support desk yet; the app
  must show "support options are not available" rather than a placeholder.
- **No daily limits are seeded.** Limits are a Product/Finance decision. The
  server must never invent an amount.
- **No corridor rates or market depth are seeded.** A pricing source and the
  aggregation rules must be connected in B2.
- **Ledger accounts are provisional.** The chart of accounts is seeded for every
  active currency but marked `is_provisional = true` until Finance and Legal
  approve it.
- **Only real reference names are used.** Countries, currencies, carriers and
  payout rails are public data, not fake operational values.

## Security rules

- `lib/` and `server/` never share simulated data. Preview data stays in
  `preview/` only.
- KYC identifiers and recipient account numbers are encrypted with AES-256-GCM
  before they reach PostgreSQL. Lookups use HMAC-SHA-256 hashes.
- OTP codes and refresh tokens are stored as hashes only.
- The API must use a least-privilege database role. The migration role is
  separate. Ledger and timeline tables reject updates and deletes at the
  database boundary, not only in application code.
- Request bodies containing personal data must never be logged. The B2 logging
  layer must redact `Authorization`, `X-Idempotency-Key`, phone numbers, names,
  account numbers and KYC identifiers.

## Next step

B2 starts with `B2.0` bootstrap endpoints in this order: `/config`, `/rates`,
OTP, `/me` and KYC, beneficiaries, then trade estimate/quote/initiate. The data
foundation above is ready for those handlers.
