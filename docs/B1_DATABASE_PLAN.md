# B1 — Database Foundation Plan

**Program**: CrossPay — PART 2 Backend
**Workstream**: B1 — Schema, double-entry ledger and quote lifecycle
**Status**: Approved for build — implementation authorised 2026-11-14
**Prepared**: 2026-11-11
**Owner**: Backend Engineering
**Approvers**: Product, Finance, Legal & Compliance, Security
**Companion documents**: `docs/api_contract.md`, `docs/DECISIONS.md`, `MASTER_PROGRESS_REPORT.md`, `FEATURE_SPEC/INDEX.md`

---

## 1. Executive summary

B1 establishes the durable data foundation for CrossPay. It is not a single
`schema.sql` file and it is not limited to the seven tables in the first outline.

B1 covers:

- identity, OTP sessions, refresh tokens and KYC records;
- server-driven reference data and multi-country configuration;
- saved recipients;
- quotes with a server-enforced expiry and single-use lifecycle;
- trades with an immutable price and recipient snapshot;
- idempotency with safe replay and concurrency control;
- a real double-entry ledger with an immutable audit trail;
- the financial event tables that B2 and B3 will use.

B1 does **not** implement HTTP endpoints, payment-provider integrations, admin
screens, a data warehouse or a fraud engine. Those remain B2, B3 and later.

The design is contract-first, migration-first and audit-first. Every financial
movement must be explainable from the database without relying on application
logs.

### Platform baseline

- PostgreSQL 15 or newer, hosted on Supabase.
- Node.js LTS with strict TypeScript for the API, hosted on Render.
- Versioned SQL migrations; `schema.sql` is generated for review only.
- One query layer for ordinary CRUD; double-entry postings use explicit SQL
  transactions and database constraints.
- The Flutter app never connects directly to PostgreSQL.
- All persisted timestamps are UTC `timestamptz`; ISO 3166 country codes and
  ISO 4217 currency codes are used throughout.

### Industry alignment

The foundation follows patterns proven by payment infrastructure rather than
inventing a local variant:

- **Idempotency** uses Stripe's model: the key belongs to one user and scope,
  a different body is rejected, a concurrent duplicate waits and replays the
  committed response, and keys expire after a bounded window.
- **Ledger** follows the standard append-only journal pattern: accounts,
  balanced single-currency transactions, immutable lines, derived balances and
  reversing entries. A posting key makes retried provider callbacks harmless.
- **Reference data** is verified against public numbering plans and operator
  publications. Carrier prefixes are hints, not identity; the payout provider
  remains authoritative.
- **Data protection** treats KYC identifiers, recipient accounts and tokens as
  restricted data, never as ordinary columns or log lines.

---

## 2. Scope and non-goals

### In scope

- PostgreSQL schema and versioned migrations.
- Reference-data seed strategy.
- Constraints, indexes, state machines and audit rules.
- Quote expiry and single-use enforcement.
- Double-entry ledger structure and posting rules.
- Idempotency storage and replay semantics.
- Security and privacy controls for stored data.
- Schema-level acceptance tests.

### Out of scope

- HTTP route handlers and request validation.
- Payment aggregator, bank, SMS and KYC provider integrations.
- Administrative UI for configuration.
- Reporting warehouse, BI extracts and long-term analytics storage.
- Fraud scoring and sanctions-screening algorithms.
- Multi-user business organisations beyond the current single-owner account
  model.

The frontend rule remains unchanged: no mocks or invented data under `lib/`.
Every value shown to a person must come from the server.

---

## 3. Design principles

1. **The server is the only source of financial truth.** The app displays status;
   it never advances a trade or calculates money.
2. **One fact, one home.** Current trade state lives on `trades`; the immutable
   history lives on `trade_events`; money lives in the journal.
3. **Money is exact.** Amounts are integer minor units with an explicit ISO 4217
   currency. Rates are fixed-precision decimals. Floating point is prohibited.
4. **Quotes are promises.** A quote has a server-issued expiry, belongs to one
   user and is consumed exactly once.
5. **Idempotency is an invariant, not a middleware afterthought.** A repeated
   request must return the original result and must never create a second
   collection, trade or ledger posting.
6. **The ledger is double-entry and immutable.** Every journal transaction
   balances to zero per currency. Corrections are reversing entries, never
   edits or deletions.
7. **Sensitive data is minimised and protected.** KYC identifiers, account
   numbers and tokens are never logged and are encrypted where required.
8. **Multi-market is a schema concern.** ISO country and currency codes, UTC
   timestamps, per-currency limits, ordered reference data and data-residency
   decisions are designed in from the start.
9. **Migrations are the source of truth.** `schema.sql` is generated for review;
   it is never hand-edited or applied as the only deployment mechanism.
10. **Legal and accounting review is a gate.** The chart of accounts and escrow
    treatment are not engineering inventions.

---

## 4. Work breakdown

The original B1.1 / B1.2 / B1.3 headings map to the workstreams below. Quote
expiry is part of B1.3, not a separate table definition.

| Workstream | Deliverable | Exit criteria |
|---|---|---|
| **B1.0 — Conventions and contract reconciliation** | ADR for IDs, money, time, statuses, migrations and sensitive-data handling; contract gaps closed in `docs/api_contract.md` | Product and Backend approve the shapes for beneficiary writes, invoice/share, market depth and refresh; no endpoint is implemented against an undocumented payload |
| **B1.1 — Identity, access and reference data** | Migrations and seed for users, KYC, tiers, OTP, refresh tokens, countries, currencies, carriers, hubs, payout rails, support and corridor settings | A clean database can serve a valid `/config` response and support OTP login and `/me` |
| **B1.2 — Recipients** | `beneficiaries` with ownership, rail integrity, encrypted destination data and soft deletion | F5.2 CRUD can be implemented without schema change |
| **B1.3 — Quotes and trades** | `quotes`, `quote_routes`, `trades`, `trade_events` and `payment_attempts` | Quote expiry, single use, price snapshots and history are enforceable in SQL transactions |
| **B1.4 — Idempotency and concurrency** | `idempotency_keys`, replay rules, conflict handling and cleanup | Two concurrent `trade/initiate` requests with the same key produce one trade and one response |
| **B1.5 — Double-entry ledger** | `ledger_accounts`, `journal_transactions`, `journal_lines`, posting keys and balance checks | Every journal transaction balances per currency; ledger rows cannot be updated or deleted |
| **B1.6 — Financial operations scaffolding** | `payment_events`, `payouts`, `refunds`, `p2p_matches` | B2/B3 can add behaviour without redesigning core financial tables |
| **B1.7 — Migrations, seed and verification** | Versioned migrations, idempotent seed, ERD, runbook and automated schema tests | Empty-database migration and seed pass in CI; all acceptance tests in section 10 pass |

Dependencies:

- B1.5 cannot be finalised until Finance and Legal approve the chart of accounts
  and escrow treatment.
- B1.1 and B1.2 cannot be finalised until the KYC retention and recipient-data
  encryption decisions are recorded.
- B2.0–B2.3 endpoint work starts only after B1.1–B1.4 pass their exit criteria.
- Payment endpoint and worker work starts only after B1.5–B1.6 pass their
  exit criteria.

### B1.0 conventions

The following conventions are fixed before the first migration:

- **Identifiers**: UUID primary keys for internal rows; no sequential database
  IDs exposed through the API. Trades also carry a unique, human-readable
  `reference`.
- **Money**: `bigint` minor units plus an ISO 4217 currency code. Rates use
  `numeric(20,10)`. No floating-point money anywhere.
- **Time**: `timestamptz`, UTC. The server clock is the only clock used for
  quote expiry, limits and audit timestamps.
- **Status values**: `text` plus `CHECK` constraints or lookup tables, so a
  status can be added without an unsafe enum migration.
- **Deletion**: soft delete for users and saved recipients where retention
  requires it; hard delete is allowed only after the retention review. Ledger
  and trade-event rows are never deleted.
- **Naming**: `snake_case` in PostgreSQL; API response mapping remains
  camelCase as documented in `docs/api_contract.md`.
- **Sensitive data**: classify before storing; encrypt restricted fields; never
  log request or response bodies containing personal data.

---

## 5. Logical data model

### 5.1 Identity and access

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `users` | Account identity and current profile state | `id uuid`, unique E.164 `phone`, `phone_verified_at`, `display_name`, `account_type` (`personal` / `business`), nullable `hub_id`, `kyc_status`, `tier_code`, `limit_currency_code`, `created_at`, `updated_at`, `deleted_at`; business accounts require a hub, personal accounts do not |
| `tiers` | Server-defined service tiers | `code` primary key, `name`, `active`, `sort_order` |
| `tier_limits` | Daily limits per tier and currency | `(tier_code, currency_code)` primary key, `daily_limit_minor`; currency references `currencies` |
| `kyc_verifications` | KYC submissions and outcomes | `user_id`, `account_type`, `legal_name`, `hub_id`, `id_type`, encrypted `id_number`, `id_number_hash`, `id_last4`, `status`, provider reference, rejection code, `submitted_at`, `verified_at`; full identifier is never returned by the API |
| `otp_challenges` | One-time-code challenges | `phone`, hashed `code`, `attempts`, `max_attempts`, `expires_at`, `resend_after_seconds`, `consumed_at`, `created_at`; plaintext codes are never stored |
| `refresh_tokens` | Rotating refresh-token family | `user_id`, unique `token_hash`, `family_id`, `expires_at`, `revoked_at`, `replaced_by_id`, `created_at`, `last_used_at` |
| `rate_limit_buckets` | Database-backed throttling where Redis is not used | `(scope, key_hash, window_start)` primary key, `count`, `expires_at`; used for OTP, name checks and sensitive writes |

`dailyUsedMinor` is **derived** from trades that count against the applicable
daily limit. It is not a stored wallet balance. The counting rule and the daily
boundary (UTC or a market time zone) require Product and Compliance approval.

### 5.2 Reference data and configuration

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `countries` | Dialling and locale metadata | `code char(2)` primary key, `name`, `dial_code`, `national_number_length`, `sort_order`, `active` |
| `currencies` | Currency metadata and display precision | `code char(3)` primary key, `name`, `country_code`, `decimals` between 0 and 6, `sort_order`, `active` |
| `carriers` | Mobile-money carrier hints | `id`, `name`, `country_code`, `prefix_pattern`, `sort_order`, `active` |
| `hubs` | Business trading hubs | `id`, `name`, `country_code`, `sort_order`, `active` |
| `payout_rails` | Mobile-money and bank destinations | `id`, `name`, `country_code`, `kind` (`mobile_money` / `bank`), `sort_order`, `active` |
| `support_settings` | Optional support contact block | Singleton row; optional `email`, `phone`, `whatsapp`, `hours`; no invented values |
| `corridor_settings` | Enabled corridors and public health metadata | `(send_currency, receive_currency)` primary key, `is_enabled`, `estimated_settle_seconds`, `status_code`, `status_level` (`healthy` / `limited` / `down`), `sort_order`, `updated_at` |

Live FX rates are supplied by the pricing source. They are not silently frozen
in `corridor_settings`. If the pricing source requires an audit cache, add a
`rate_snapshots` table with source, rate, status and `fetched_at`; that is a
separate decision.

The five `/config` lists must always be queryable and ordered:
`currencies`, `hubs`, `payoutRails`, `countries`, `carriers`. The first country
is the default on the phone screen. `payout_rails.kind` is mandatory because the
Flutter model rejects a rail without it.

### 5.3 Recipients

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `beneficiaries` | Saved recipients owned by one user | `id`, `user_id`, `rail_id` references `payout_rails`, `name`, encrypted `account_or_phone`, `account_last4`, `account_hash`, `name_verified`, `created_at`, `updated_at`, `deleted_at`; unique active `(user_id, rail_id, account_hash)` |

API mapping: `accountOrPhone` is decrypted for the owner only; `kycVerified`
maps to `name_verified`. The database field is named for what it means: a
destination name check, not full KYC of the recipient.

### 5.4 Quotes

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `quotes` | One server-issued price and lock window | `id`, `user_id`, `send_currency`, `receive_currency`, `send_amount_minor`, `rate numeric(20,10)`, `quoted_at`, `expires_at`, `status` (`active` / `consumed` / `expired` / `cancelled`), `consumed_at`, `created_at`; positive amounts; `expires_at > quoted_at`; index `(user_id, expires_at)` |
| `quote_routes` | Route snapshots returned by `/trade/quote` | `quote_id`, `route` (`p2p` / `bank`), `fee_bps`, `fee_minor`, `payout_minor`, `total_debit_minor`, `estimated_min_seconds`, `estimated_max_seconds`, `is_recommended`, `is_available`, `matching_density_percent`, `status_code`, `status_level`, `safeguard_code`, `fee_breakdown jsonb`, `created_at`; unique `(quote_id, route)` |

Rules:

- A quote belongs to exactly one user.
- Quote routes are immutable after creation.
- `POST /trade/initiate` locks the quote row, verifies ownership, status and
  `expires_at > now()`, then marks it `consumed` in the same transaction that
  creates the trade.
- A quote cannot be consumed by two trades. Expired quotes remain for audit
  until the retention window ends; a worker marks them `expired`.
- The trade copies the chosen route's rate, fees and payout. It never reads a
  quote for later display or calculation.

### 5.5 Trades and status history

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `trades` | Current trade state and immutable financial snapshot | `id`, unique server-issued `reference`, `user_id`, `quote_id`, `quote_route_id`, `route`, `status`, `send_currency`, `receive_currency`, `send_amount_minor`, `fee_minor`, `fee_bps`, `receive_amount_minor`, `rate`, `beneficiary_name`, `beneficiary_rail_id`, encrypted `beneficiary_account`, `beneficiary_account_last4`, optional `beneficiary_reference`, `verification_hash`, `current_payment_attempt_id`, `created_at`, `updated_at`, `completed_at`, `cancelled_at`, `failure_code` |
| `trade_events` | Append-only timeline returned by `/trades/{id}/history` | `id`, `trade_id`, `status`, `at timestamptz`, optional `note_code`, `actor` (`server` / `provider` / `user` / `system`), `created_at`; index `(trade_id, at, id)` |
| `payment_attempts` | Collection details for `/trade/initiate` and provider callbacks | `id`, `trade_id`, provider, external reference, `method` (`push` / `manual`), `amount_minor`, `currency`, `push_sent`, `network_name`, `push_timeout_seconds`, `poll_interval_seconds`, manual method/number/reference, status, `created_at`, `updated_at`; unique provider reference where present |

Trade status is restricted to:

`pending_deposit`, `escrowed`, `matching`, `matched`, `disbursing`,
`completed`, `expired`, `refunded`, `failed`, `cancelled`.

Only the server may change it. Every change appends a `trade_events` row in the
same transaction. A database check constraint rejects unknown statuses; the
service layer enforces the allowed transition graph. Client input never sets a
status.

The trade row is the current-state snapshot. Financial display uses the copied
snapshot, not a live join to the quote. Beneficiary details are snapshotted so a
later recipient edit or deletion cannot change an existing trade.

### 5.6 Idempotency

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `idempotency_keys` | Safe replay and concurrency control for writes | `id`, `user_id`, `scope`, `key`, `request_hash`, `status` (`in_progress` / `succeeded` / `failed`), `response_status`, encrypted `response_body`, `resource_type`, `resource_id`, `created_at`, `completed_at`, `expires_at`; unique `(user_id, scope, key)`; index expiry |

Semantics:

- The scope identifies the operation, for example `trade.initiate`,
  `beneficiary.create`, `trade.cancel` or `trade.share`.
- The same key with the same request hash replays the stored result.
- The same key with a different request hash returns `409
  IDEMPOTENCY_KEY_REUSED`.
- A duplicate while the first request is still `in_progress` waits on the
  unique index and replays the committed result. It never executes the
  operation a second time. If the server cannot wait, or finds a committed
  in-progress row, it returns a deterministic `409 IDEMPOTENCY_IN_PROGRESS`
  with `Retry-After`; if the first transaction rolls back, the waiting request
  acquires the key and proceeds.
- The business write and the idempotency completion commit in one database
  transaction. A crash before commit leaves no half-applied trade.
- The response snapshot must be encrypted when it contains personal data.
  Retention is short and configurable; the key is not kept forever.
- `payment-claim` uses a key even though its response body is not consumed, so
  repeated taps cannot cause repeated provider checks or side effects.

### 5.7 Double-entry ledger

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `ledger_accounts` | Chart of accounts | `id`, unique `code`, `name`, `type` (`asset` / `liability` / `equity` / `revenue` / `expense`), `normal_side` (`debit` / `credit`), `currency_code`, `active`, `created_at` |
| `journal_transactions` | One balanced financial event in one currency | `id`, unique `posting_key`, `kind`, `trade_id`, optional payment-event/payout/refund references, `currency_code`, `fx_group_id`, `reverses_transaction_id`, `occurred_at`, `created_at` |
| `journal_lines` | Debit and credit lines | `transaction_id`, `account_id`, signed `amount_minor bigint` (nonzero), `created_at`; deferred constraint/trigger enforces the sum is zero for every transaction |

Rules:

- Every journal transaction is single-currency and balances to zero.
- Cross-currency conversions are represented by two linked transactions sharing
  an `fx_group_id`, with explicit FX clearing account lines.
- `posting_key` is unique per economic event, for example
  `payment_event:<id>:deposit`, so a retried webhook cannot post twice.
- Ledger rows are append-only. The runtime database role has no `UPDATE` or
  `DELETE` permission on journal tables. Corrections use a reversing transaction.
- `journal_lines` link to trades and payment events through the transaction;
  there is no free-text `counterparty` column.
- Account balances are derived by summing lines. No customer wallet or spendable
  balance is stored.
- The chart of accounts must include, at minimum, partner trust cash, payout
  clearing, fee revenue, FX position, trade payable and refund payable. Finance
  and Legal must approve the exact accounts and posting rules before B1.5 is
  signed off.

The ledger records economic events, not application intent. A trade is not
posted merely because it was created. Postings occur when a deposit is
confirmed, a fee is earned, a payout is sent or a refund is paid.

### 5.8 Financial operations scaffolding

These tables are created in B1 because the ledger and idempotency reference
them, but their behaviour belongs to B2/B3.

| Table | Purpose | Key columns and constraints |
|---|---|---|
| `payment_events` | Verified provider callbacks | provider, unique external event ID, event type, `trade_id`, `payment_attempt_id`, `signature_verified`, payload hash, minimal payload, `received_at`, `processed_at`, status |
| `payouts` | Outbound disbursements | `trade_id`, provider, external reference, amount, currency, status, attempt count, last error code, requested/completed timestamps; unique provider reference |
| `refunds` | Returned funds | `trade_id`, optional payment event, amount, currency, reason code, provider reference, status, requested/completed timestamps |
| `p2p_matches` | Peer-to-peer matching records | buy trade, sell trade, amounts, currencies, status, matched/released timestamps; unique pair |

Invoice and export links remain a decision. Signed, short-lived URLs may avoid
a table entirely; persisted one-time tickets require an `invoice_links` or
`export_tickets` table. The decision is recorded before B2.3.

---

## 6. State and lifecycle rules

### 6.1 Trade status

Allowed statuses are the ten values in the contract. The transition graph must
be documented and enforced server-side. A rejected transition returns a stable
4xx code and does not append an event.

`trade_events` is the audit trail. It is append-only, ordered by `(at, id)`, and
never rewritten. `GET /trades/{id}/history` returns those rows oldest first.

### 6.2 Quote lifecycle

- `active` → `consumed` on successful trade initiation.
- `active` → `expired` when the expiry worker runs.
- `active` → `cancelled` only by an explicit business rule.

Consumed and expired quotes are retained for audit and are never reactivated.

### 6.3 Payment, payout and refund states

Each operational table has an explicit status check and an allowed transition
graph. Provider callbacks are accepted only after signature verification and
duplicate-event detection. A callback is never allowed to set an arbitrary
trade status directly; the service maps a verified financial event to a valid
transition.

---

## 7. Security, privacy and compliance

### 7.1 Data classification

| Class | Examples | Handling |
|---|---|---|
| Public | Currency names, country names, public support block | Cacheable; no personal data |
| Internal | Trade status, amounts, corridor settings | Authenticated access; not public |
| Confidential | Phone numbers, names, recipient accounts, legal names | Encrypted in transit and at rest; access-logged; never in application logs |
| Restricted | National ID / TIN, KYC documents, refresh tokens, idempotency response bodies containing PII | Application-level encryption or tokenisation, key rotation, strict least privilege |

### 7.2 Controls

- TLS everywhere; encrypted database storage and encrypted backups.
- Application-level envelope encryption for restricted fields; encryption keys
  live in the hosting secret manager, never in the database.
- OTP codes and refresh tokens are stored only as strong hashes.
- Refresh tokens rotate on use; reuse revokes the token family.
- PIN and biometric data remain on the device. The backend stores no PIN and no
  biometric template.
- Structured logs redact `Authorization`, `X-Idempotency-Key`, request bodies,
  phone numbers, names, account numbers and ID values. A log-redaction test is
  part of acceptance.
- The runtime database role cannot run DDL and cannot update or delete ledger
  rows. Migrations use a separate role.
- The app never connects directly to PostgreSQL. Supabase is the database host,
  not a public data API. RLS is not a substitute for API authorisation.
- Rate limits cover OTP request/verify, recipient checks and sensitive writes.
- Data retention and deletion policies are defined per market and reviewed by
  Legal. KYC data has an explicit retention period and deletion path.
- Data residency is a recorded decision before production. Supabase region
  selection must match the approved policy for the operating markets.
- KYC, AML and sanctions obligations are reviewed by Legal and Compliance before
  any real-money pilot.

---

## 8. Migrations, seed and operations

### 8.1 Migrations

- Location: `server/db/migrations/`.
- Naming: `NNNN_short_description.sql`.
- Forward-only, transactional where PostgreSQL permits, reviewed before merge.
- Destructive changes follow expand-and-contract; no column is dropped while an
  older API version may still read it.
- `schema.sql` is generated from migrations for review. It is never the
  deployment mechanism.
- Staging is migrated before production. A backup and restore point is taken
  before each production migration.

### 8.2 Seed

- Seed data is idempotent and versioned.
- Required lists: countries, currencies, carriers, hubs and payout rails.
- `payout_rails.kind` is mandatory.
- Support contact values are seeded only when real; otherwise the block is
  omitted and the app says support options are unavailable.
- No simulated rates or fake trade data are inserted into the real database.

### 8.3 Environments and operations

- Separate local, staging and production databases. Production data never
  enters development.
- Runtime and migration database users are separate.
- Connection pooling and SSL are configured according to the hosting plan.
- Backups, point-in-time recovery and a restore drill are required before the
  pilot.
- Alerts cover migration failure, ledger imbalance, idempotency conflicts,
  callback signature failure and unusual OTP failure rates.
- Slow-query review covers `trades(user_id, created_at)`,
  `trade_events(trade_id, at)`, `quotes(user_id, expires_at)` and
  `idempotency_keys(expires_at)`.

---

## 9. Contract reconciliation status

`docs/api_contract.md` is the backend contract of record. B1.0 closed the gaps
that blocked schema work on 2026-11-14:

| Gap | Status |
|---|---|
| Beneficiary `POST` / `PATCH` / `DELETE` shapes | Documented, including ownership and idempotency rules |
| `GET /trades/{id}/invoice`, `POST /trades/{id}/share` | Documented, including expiry and error codes |
| `GET /market/depth` | Documented with the exact fields the Flutter parser reads |
| `POST /auth/refresh` | Shape final; token rotation and family revocation documented. The Flutter constant is added when F5.3 is wired |
| `kycStatus` mapping | API returns `pending`, `verified` or `rejected`; `not_started` is internal and is never returned by `/me` because profile completion gates the pre-KYC state |
| Idempotency conflicts | Same key and body replays with `Idempotency-Replay: true`; different body is `409 IDEMPOTENCY_KEY_REUSED`; a duplicate normally waits and replays, or returns `409 IDEMPOTENCY_IN_PROGRESS` with `Retry-After` when it cannot wait |

No endpoint is implemented against an undocumented payload. The first migration
was written only after this table was complete.

---

## 10. Acceptance criteria

B1 is complete when all of the following are true. Engineering items were
verified on 2026-11-14; the evidence is in `docs/B1_IMPLEMENTATION.md`.

- [x] Migrations apply cleanly to an empty PostgreSQL database and are
      idempotent. The previous staging snapshot check remains a deployment
      step.
- [x] Seed is idempotent and `/config` returns all five required lists plus the
      optional support block in a shape the Flutter parser accepts.
- [x] `payoutRails.kind` is present and validated.
- [x] A quote can be consumed exactly once; an expired quote is rejected with
      `QUOTE_EXPIRED`.
- [x] The idempotency primitive proves one concurrent request produces one
      result. The B2 endpoint test will add the trade and collection rows.
- [x] A different body with the same key returns `IDEMPOTENCY_KEY_REUSED`.
- [x] Every journal transaction balances per currency; a deliberate imbalance is
      rejected.
- [x] Ledger rows cannot be updated or deleted. The trigger blocks the table
      owner; the runtime role also has no such privileges.
- [x] A repeated posting key cannot create a second ledger posting. The B3
      webhook handler will call this primitive.
- [x] Trade status changes append ordered history and reject illegal transitions.
- [x] Refresh-token rotation is enforced and reuse revokes the family.
- [x] OTP codes and refresh tokens are stored only as hashes.
- [x] KYC and recipient identifiers are encrypted. B2 must add the log-redaction
      test for the HTTP layer.
- [x] The ERD and migration runbook are delivered; the data-classification
      record is in this plan and `server/db/RUNBOOK.md`.
- [ ] Finance and Legal have signed off the chart of accounts and escrow
      treatment. This is a governance gate, not an engineering defect.

---

## 11. Risks and open decisions

| Decision or risk | Owner | Blocks | Recommended position |
|---|---|---|---|
| Escrow/trust legal structure and chart of accounts | Founder + Finance + Legal | B1.5 | Do not finalise ledger postings without written approval |
| KYC data retention and encryption/key management | Legal + Security | B1.1 | Encrypt restricted identifiers; define retention before pilot |
| Data residency for target markets | Founder + Legal | Production | Choose the Supabase region only after the market policy is approved |
| Where live FX rates come from | Product + Backend | B2.0 | Pricing source is authoritative; no invented rates |
| Daily-limit counting rule and time zone | Product + Compliance | B1.1/B1.2 | Define before `/me` is implemented |
| Invoice/export link persistence | Product + Backend | B2.3 | Default to signed short-lived URLs unless one-time audit is required |
| P2P matching model | Product + Backend | B3.2 | Decide whether `p2p_matches` is a ledger-adjacent record or derived from trades |
| Contract gaps above | Product + Backend | B1.0 | Close before endpoint work |

---

## 12. Approval and next step

This plan is the B1 baseline. Implementation starts only after:

1. Product and Backend approve B1.0 contract reconciliation.
2. Legal, Compliance and Finance approve the data-retention and ledger gates.
3. The ERD and migration strategy are reviewed.

The immediate next deliverable is **B1.0**: a one-page decisions record plus the
updated contract. The first migration is written only after that review.

### Build authorisation and provisional assumptions (2026-11-14)

The founder has authorised B1 implementation before the four deferred decisions
in section 11 are final. Engineering proceeds with the provisional positions
below. Each is isolated behind configuration or clearly marked in the schema so
that a later decision changes data and policy, not the data model.

| Deferred decision | Provisional build position | Reversal path |
|---|---|---|
| B1 scope | Full core foundation: identity, reference data, recipients, quotes, trades, idempotency and ledger scaffolding | None expected; the scope matches the launch path |
| Chart of accounts and escrow treatment | Structural double-entry rules are final. Seed accounts are marked provisional and no production posting rules are enabled | Finance/Legal approve or replace account codes before the first real posting |
| KYC retention and key management | Restricted identifiers use application-level AES-256-GCM envelope encryption. Key is supplied by `DATA_ENCRYPTION_KEY` and never stored in the database. `KYC_RETENTION_DAYS` defaults to 2555 (seven years) and is configurable | Change the key source or retention setting; re-encryption is a controlled migration |
| Daily-limit rule and time zone | Daily usage is derived from trades created in the current UTC calendar day, excluding `cancelled`, `expired` and `failed`. `LIMIT_TIMEZONE` defaults to `UTC` | Change the derivation query and time-zone setting; no balance table is affected |
| Invoice and export links | Signed, short-lived URLs. No persistence table is created in B1 | Add `invoice_links` / `export_tickets` if one-time audit becomes a requirement |
| P2P matching | `p2p_matches` is scaffolded only. Queue depth is derived from open trades until B3 | B3 defines the matching engine; the table is already referenced by the ledger model |

Implementation is split into reviewable migrations and verified against an
ephemeral PostgreSQL instance. The runtime database role cannot modify ledger
history. No production credentials are required or stored in this repository.

---

## Report End — No fluff. Just facts.
