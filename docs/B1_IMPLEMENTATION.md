# B1 implementation record

**Program**: CrossPay — PART 2 Backend
**Workstream**: B1 — Database foundation
**Status**: Built and verified 2026-11-14
**Plan of record**: `docs/B1_DATABASE_PLAN.md`
**Contract**: `docs/api_contract.md`
**Code**: `server/`

---

## 1. What was delivered

| Workstream | Delivered | Location |
|---|---|---|
| B1.0 Conventions and contract | IDs, money, time, statuses, sensitive-data rules; beneficiary writes, invoice/share, market depth and refresh shapes reconciled | `docs/B1_DATABASE_PLAN.md`, `docs/api_contract.md` |
| B1.1 Identity and reference data | Users, KYC, tiers, OTP, refresh-token families, countries, currencies, carriers, hubs, payout rails, support, corridor settings | `server/db/migrations/0001_reference_data.sql`, `0002_identity_access.sql` |
| B1.2 Recipients | Owned, encrypted beneficiary destinations with soft delete and duplicate prevention | `0003_recipients_trading.sql` |
| B1.3 Quotes and trades | User-bound quotes, immutable route snapshots, single-use consumption, trade price/recipient snapshots, append-only timeline | `0003_recipients_trading.sql`, `server/src/quotes.ts` |
| B1.4 Idempotency | Request hash, response replay, different-body rejection, concurrency-safe acquisition, pruning | `0004_idempotency.sql`, `server/src/idempotency.ts` |
| B1.5 Ledger | Accounts, balanced journal transactions, immutable lines, posting keys, reversals, derived balances | `0006_ledger.sql`, `server/src/ledger.ts` |
| B1.6 Financial scaffolding | Payment events, payouts, refunds, P2P matches | `0005_financial_operations.sql` |
| B1.7 Migrations and verification | Checksum-locked runner, idempotent seed, ERD, runbook, local verify, 31 integration tests | `server/`, `server/db/ERD.md`, `server/db/RUNBOOK.md` |

Additional identity logic delivered beyond the bare schema:

- `server/src/auth/otp.ts` — one-time codes, attempt limits, expiry, one active
  code per phone, one successful consumption.
- `server/src/auth/refresh-tokens.ts` — hashed refresh tokens, family rotation,
  family revocation on reuse and expiry handling.

---

## 2. Database model

The schema is grouped into five concerns:

1. **Reference data** — `countries`, `currencies`, `carriers`, `hubs`,
   `payout_rails`, `support_settings`, `corridor_settings`, `tiers`,
   `tier_limits`, `config_versions`.
2. **Identity** — `users`, `kyc_verifications`, `otp_challenges`,
   `refresh_tokens`, `rate_limit_buckets`.
3. **Trading** — `beneficiaries`, `quotes`, `quote_routes`, `trades`,
   `trade_events`, `payment_attempts`.
4. **Idempotency** — `idempotency_keys`.
5. **Money movement** — `ledger_accounts`, `journal_transactions`,
   `journal_lines`, `payment_events`, `payouts`, `refunds`, `p2p_matches`.

Full diagram: `server/db/ERD.md`.

### Money and time

- Amounts are `bigint` minor units plus a currency code. Rates are
  `numeric(20,10)`. Floating point is not used.
- All timestamps are `timestamptz` in UTC.
- Currency `decimals` comes from `/config`; the app formats from the server
  value.
- `dailyUsedMinor` is derived from trades; no wallet or spendable balance is
  stored.

### Quote lifecycle

A quote belongs to one user. `trades.quote_id` is unique, so one quote can
produce at most one trade. `consumeQuote()` locks the quote row, checks
ownership, status and `expires_at`, then marks it consumed in the same
transaction that inserts the trade. Expired, consumed and cancelled quotes can
never be reactivated.

### Trade snapshot and timeline

The trade copies the chosen route’s rate, fee, payout and recipient details.
Later quote or beneficiary changes cannot alter it. `trade_events` is written by
a database trigger on every status change, so a service cannot forget the audit
trail. `trade_status_transitions` makes the allowed graph configurable and
rejects illegal jumps.

### Idempotency

`(user_id, scope, key)` is unique. The service stores a request hash and an
encrypted response body.

- Same key and same hash: replay the original status/body.
- Same key and different hash: `IDEMPOTENCY_KEY_REUSED`.
- Concurrent duplicate: the insert waits on the unique index. If the first
  transaction commits, the second replays it; if the first rolls back, the
  second acquires the key. A committed in-progress row returns
  `IDEMPOTENCY_IN_PROGRESS`.
- The business write and idempotency completion belong to one transaction.
- Completed keys are pruned after `IDEMPOTENCY_TTL_SECONDS` (default 24 hours).

### Ledger

- `ledger_accounts` is a chart of accounts, one account per currency.
- `journal_transactions` is single-currency, carries a unique `posting_key`, and
  links to the trade, payment event, payout or refund that caused it.
- `journal_lines` are signed minor units; a deferred constraint trigger requires
  at least two lines, the same account currency and a zero sum at commit.
- Ledger tables reject `UPDATE` and `DELETE` with a database trigger. The
  runtime role also has no such privileges.
- Balances are derived in `ledger_account_balances`. Corrections are reversing
  entries.
- The seeded chart is marked `is_provisional = true`. Finance and Legal must
  approve it before real postings.

### Security

- AES-256-GCM application encryption for KYC identifiers, recipient accounts,
  trade recipient snapshots and idempotency response bodies.
- HMAC-SHA-256 for duplicate detection and lookups.
- OTP codes and refresh tokens are hashes only.
- Refresh tokens rotate; reuse revokes the family. The rotate function returns
  `state: 'reused'` and the caller must commit that revocation before answering
  401.
- PINs and biometrics never enter the database.

---

## 3. Verification evidence

Run from `server/`:

```sh
npm run typecheck
# tsc --noEmit -> no output, exit 0

npm test
# 31 tests, 7 suites, 0 failures

npm run verify:local
# ok: true, fresh PostgreSQL 17 database
```

`npm run verify:local` output:

```json
{
  "ok": true,
  "failures": [],
  "counts": {
    "migrations": 7,
    "currencies": 6,
    "payout_rails": 18,
    "ledger_accounts": 48,
    "tier_limits": 0,
    "support_settings": 0
  },
  "configLists": {
    "currencies": 6,
    "hubs": 5,
    "payoutRails": 18,
    "countries": 6,
    "carriers": 15
  },
  "supportConfigured": false
}
```

The test suite starts an ephemeral PostgreSQL 17 cluster with
`embedded-postgres`. No Docker, local PostgreSQL or hosted database is needed.

| Test file | What it proves |
|---|---|
| `test/schema.test.ts` | Migrations apply once and are idempotent; seed is idempotent; `/config` has all five ordered lists and payout kinds; no invented support/limits/corridors; invalid rows are rejected |
| `test/trading.test.ts` | Quote single-use and expiry; trade snapshots; trigger-written timeline; illegal transitions rejected; concurrent idempotency; rollback acquisition |
| `test/ledger.test.ts` | Balanced posting; unbalanced commit rejected; mixed currencies rejected; append-only history; duplicate posting keys rejected; reversing entries |
| `test/security.test.ts` | Encryption round-trip and tamper detection; KYC/recipient ciphertext; hash-only OTP/refresh tokens; OTP attempt limits; refresh rotation and family revocation |

---

## 4. Acceptance status

| Acceptance criterion | Status |
|---|---|
| Migrations apply cleanly to an empty database and are idempotent | ✅ tested |
| Seed is idempotent and `/config` returns all five lists | ✅ tested |
| `payoutRails.kind` present and validated | ✅ tested |
| A quote is consumed exactly once | ✅ tested |
| Expired quote rejected | ✅ tested |
| Concurrent `trade/initiate` with one key creates one result | ✅ idempotency primitive tested |
| Different body with the same key is rejected | ✅ tested |
| Every journal transaction balances per currency | ✅ tested |
| Ledger rows cannot be updated or deleted | ✅ tested |
| Repeated provider callback cannot post twice | ✅ unique `posting_key` tested |
| Trade status changes append ordered history and illegal transitions fail | ✅ tested |
| Refresh-token rotation and reuse revocation | ✅ tested |
| OTP and refresh tokens stored only as hashes | ✅ tested |
| KYC and recipient identifiers encrypted | ✅ tested |
| ERD, migration runbook and rollback note | ✅ delivered |
| Finance and Legal approve chart of accounts and escrow treatment | ⏳ governance gate, intentionally open |

The engineering acceptance criteria are complete. The chart of accounts remains
provisional and no production money movement should be enabled until Finance and
Legal sign off.

---

## 5. Intentional gaps and deferred decisions

These are deliberate; see section “Build authorisation and provisional
assumptions” in `docs/B1_DATABASE_PLAN.md`.

- **No HTTP API.** B1 is the data foundation. B2 owns Fastify/Express routes,
  JWT issuance and HTTP error mapping.
- **No live pricing.** `corridor_settings` is empty and no rate is seeded. A
  pricing source must be connected in B2.
- **No real support block.** The app must keep saying support options are not
  available until a real desk exists.
- **No daily limits.** `tier_limits` is empty. The server must not invent a
  limit; Product/Finance must set them.
- **Provisional chart of accounts.** Account codes and names are structural
  placeholders for Finance/Legal review.
- **Invoice/export links.** Signed short-lived URLs are the provisional
  position; no persistence table is created.
- **KYC retention.** Seven years is a configurable provisional default, not a
  legal conclusion.
- **Daily-limit time zone.** UTC default, configurable, pending Product and
  Compliance.

---

## 6. Next step — B2

B2 should be built in boot order, not in the old B2/B3 order:

1. `/config` and `/rates` (with a real pricing source or an honest unavailable
   response).
2. OTP request/verify, JWT issuance and refresh rotation.
3. `/me`, KYC submission and masked status.
4. Beneficiary CRUD and `/beneficiaries/check`.
5. Trade estimate, quote, initiate, status, history, cancel and payment-claim.
6. Analytics, export, market depth and invoice/share.
7. Payment webhooks, payouts, refunds and P2P matching.

The database primitives for steps 2–6 already exist and are tested.

---

## 7. Reference notes

The design was checked against public payment-industry practice and public
numbering data:

- Stripe idempotency semantics:
  <https://docs.stripe.com/api/idempotent_requests>
- Brandur Leach, idempotency keys in PostgreSQL:
  <https://brandur.org/fragments/idempotency-keys-crunchy>
- Tanzania telephone numbering:
  <https://en.wikipedia.org/wiki/Telephone_numbers_in_Tanzania>
- Kenya telephone numbering:
  <https://en.wikipedia.org/wiki/Telephone_numbers_in_Kenya>
- Safaricom numbering expansion:
  <https://www.safaricom.co.ke/media-center-landing/press-releases/safaricom-rolls-out-0112-0113-0114-and-0115-phone-numbers>

Carrier prefixes are hints only. The payout provider remains authoritative for
the destination network and account status.
