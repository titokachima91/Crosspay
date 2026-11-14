# CrossPay B1 entity relationship diagram

The diagram is grouped by responsibility. Cardinality is the enforcement in the
migrations; `RESTRICT` and soft-delete rules are described in
`db/migrations/`.

```mermaid
erDiagram
  countries ||--o{ currencies : "issues"
  countries ||--o{ carriers : "operates"
  countries ||--o{ hubs : "hosts"
  countries ||--o{ payout_rails : "pays out in"

  tiers ||--o{ users : "assigns"
  tiers ||--o{ tier_limits : "has"
  currencies ||--o{ tier_limits : "denominates"

  users ||--o{ kyc_verifications : "submits"
  users ||--o{ refresh_tokens : "owns"
  users ||--o{ beneficiaries : "saves"
  users ||--o{ quotes : "requests"
  users ||--o{ trades : "initiates"
  users ||--o{ idempotency_keys : "scopes"

  payout_rails ||--o{ beneficiaries : "destinates"
  payout_rails ||--o{ trades : "snapshots"

  quotes ||--o{ quote_routes : "offers"
  quotes ||--o| trades : "is consumed by one"
  quote_routes ||--o| trades : "is copied by one"

  trades ||--o{ trade_events : "records"
  trades ||--o{ payment_attempts : "collects"
  trades ||--o{ payment_events : "receives callbacks"
  trades ||--o{ payouts : "pays out"
  trades ||--o{ refunds : "refunds"
  trades ||--o{ p2p_matches : "matches buy side"
  trades ||--o{ p2p_matches : "matches sell side"

  payment_attempts ||--o{ payment_events : "confirms"
  payment_events ||--o{ refunds : "triggers"

  currencies ||--o{ ledger_accounts : "denominates"
  ledger_accounts ||--o{ journal_lines : "contains"
  journal_transactions ||--o{ journal_lines : "balances"
  journal_transactions ||--o| journal_transactions : "reverses"
  trades ||--o{ journal_transactions : "posts"
  payment_events ||--o{ journal_transactions : "posts"
  payouts ||--o{ journal_transactions : "posts"
  refunds ||--o{ journal_transactions : "posts"

  users {
    uuid id PK
    text phone UK
    text display_name
    text account_type
    text hub_id FK
    text kyc_status
    text tier_code FK
    char3 limit_currency_code FK
    timestamptz created_at
    timestamptz deleted_at
  }

  kyc_verifications {
    uuid id PK
    uuid user_id FK
    text id_type
    bytea id_number_encrypted
    text id_number_hash
    text id_last4
    text status
    timestamptz submitted_at
    timestamptz verified_at
  }

  beneficiaries {
    uuid id PK
    uuid user_id FK
    text rail_id FK
    text name
    bytea account_or_phone_encrypted
    text account_hash
    boolean name_verified
    timestamptz deleted_at
  }

  quotes {
    uuid id PK
    uuid user_id FK
    char3 send_currency FK
    char3 receive_currency FK
    bigint send_amount_minor
    numeric rate
    timestamptz expires_at
    text status
    timestamptz consumed_at
  }

  quote_routes {
    uuid id PK
    uuid quote_id FK
    text route
    integer fee_bps
    bigint fee_minor
    bigint payout_minor
    bigint total_debit_minor
    boolean is_recommended
    jsonb fee_breakdown
  }

  trades {
    uuid id PK
    text reference UK
    uuid user_id FK
    uuid quote_id FK,UK
    uuid quote_route_id FK
    text status
    char3 send_currency FK
    char3 receive_currency FK
    bigint send_amount_minor
    bigint fee_minor
    bigint receive_amount_minor
    numeric rate
    text beneficiary_name
    text beneficiary_rail_id FK
    bytea beneficiary_account_encrypted
    text verification_hash
    timestamptz created_at
  }

  trade_events {
    bigint id PK
    uuid trade_id FK
    text status
    timestamptz at
    text actor
  }

  payment_attempts {
    uuid id PK
    uuid trade_id FK
    text method
    bigint amount_minor
    char3 currency_code FK
    boolean push_sent
    text manual_method_code
    text status
  }

  idempotency_keys {
    uuid id PK
    uuid user_id FK
    text scope
    text key
    text request_hash
    text status
    integer response_status
    bytea response_body_encrypted
    timestamptz expires_at
  }

  ledger_accounts {
    uuid id PK
    text code UK
    text type
    text normal_side
    char3 currency_code FK
    boolean is_provisional
  }

  journal_transactions {
    uuid id PK
    text posting_key UK
    text kind
    char3 currency_code FK
    uuid trade_id FK
    uuid payment_event_id FK
    uuid payout_id FK
    uuid refund_id FK
    uuid reverses_transaction_id FK
  }

  journal_lines {
    bigint id PK
    uuid transaction_id FK
    uuid account_id FK
    bigint amount_minor
  }

  payment_events {
    uuid id PK
    text provider
    text provider_event_id UK
    text event_type
    uuid trade_id FK
    boolean signature_verified
    text status
  }

  payouts {
    uuid id PK
    uuid trade_id FK
    text provider
    bigint amount_minor
    char3 currency_code FK
    text status
  }

  refunds {
    uuid id PK
    uuid trade_id FK
    uuid payment_event_id FK
    bigint amount_minor
    char3 currency_code FK
    text status
  }

  p2p_matches {
    uuid id PK
    uuid buy_trade_id FK
    uuid sell_trade_id FK
    text status
  }
```

## Invariants not visible in the ERD

- A quote belongs to one user and can be consumed by at most one trade
  (`trades.quote_id` is unique).
- A trade route must belong to the same quote
  (`(quote_route_id, quote_id)` composite foreign key).
- `trade_events` is written by the `trades` trigger and is append-only.
- `trade_status_transitions` controls every status update.
- Every `journal_transactions` row is single-currency; its lines must sum to
  zero and use accounts of that currency. The check is a deferred constraint
  trigger, so it runs at commit.
- `journal_transactions` and `journal_lines` reject `UPDATE` and `DELETE`.
- `posting_key` is unique, which makes a retried provider callback harmless.
- Balances come from `ledger_account_balances`; no spendable wallet is stored.
