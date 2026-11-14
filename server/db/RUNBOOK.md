# CrossPay B1 migration and operations runbook

This runbook covers the database foundation only. The HTTP API, payment
provider workers and monitoring stack arrive in B2/B3.

## 1. Roles

Use two database roles. Never run the API as the migration owner.

| Role | Purpose | Rights |
|---|---|---|
| `crosspay_migrator` | Runs migrations and seed | Owns the schema; DDL |
| `crosspay_runtime` | API process | DML on operational tables, no DDL, no ledger mutation |

Example bootstrap (run as the database owner, not from application code):

```sql
CREATE ROLE crosspay_runtime LOGIN PASSWORD '<from secret manager>';
GRANT CONNECT ON DATABASE crosspay TO crosspay_runtime;
GRANT USAGE ON SCHEMA public TO crosspay_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO crosspay_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO crosspay_runtime;

REVOKE INSERT, UPDATE, DELETE ON schema_migrations FROM crosspay_runtime;
REVOKE UPDATE, DELETE ON journal_transactions, journal_lines, trade_events
  FROM crosspay_runtime;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO crosspay_runtime;
```

The append-only triggers are a second line of defence. They block ledger and
timeline changes even for the table owner; only a superuser who disables the
trigger can bypass them, and that is an incident.

Supabase is the database host, not a public data API. Do not expose the
`anon` role or PostgREST table access to the app. RLS is not a substitute for
API authorization.

## 2. Migration procedure

Migrations are forward-only. Each file runs in a transaction. The runner stores
a SHA-256 checksum in `schema_migrations`; editing a file that was already
applied is drift and the runner stops.

### Staging

1. Confirm the release commit and the migration list.
2. Take a backup or confirm point-in-time recovery is enabled.
3. Set `DATABASE_URL` to the staging migration role.
4. Run:

   ```sh
   npm run migrate
   npm run seed
   npm run verify
   ```

5. Run the integration tests against the staging snapshot if the change is
   financial or touches a guarded table.

### Production

1. Announce the maintenance window if the migration locks a large table.
2. Confirm a recent backup and a restore point.
3. Apply the migration **before** deploying API code that needs the new shape
   (expand-and-contract).
4. Run `npm run verify` and inspect the JSON output.
5. Deploy the API.
6. Contract old columns only in a later release, after no deployed API version
   reads them.

### A failed migration

- The migration runner rolls the file back and does not record it. Fix the SQL,
  test it on a fresh database, then rerun.
- Do **not** edit an already-applied file and rerun. The checksum check will
  stop the run. Write a new corrective migration.
- If production is already damaged, restore to the last good point in time and
  replay the verified migrations.

## 3. Seed procedure

```sh
npm run seed
```

The seed is idempotent and uses `ON CONFLICT`. It updates reference names,
prefixes, rail kinds and provisional ledger account metadata. It deliberately
does **not** create:

- support contacts;
- tier limits;
- corridor rates or market depth;
- simulated trades, beneficiaries or KYC records.

If a real support desk is configured, editing `support_settings` is an
operational change. Do not put placeholder values in the repository.

## 4. Daily checks

```sql
-- Must return zero rows. Any row is a ledger defect.
SELECT * FROM journal_transaction_balances WHERE balance_minor <> 0;

-- Must return zero rows; posting_key is unique.
SELECT posting_key, count(*)
FROM journal_transactions
GROUP BY posting_key
HAVING count(*) > 1;

-- Expired active quotes waiting for the worker.
SELECT count(*) FROM quotes WHERE status = 'active' AND expires_at <= now();

-- Idempotency rows eligible for pruning.
SELECT count(*) FROM idempotency_keys
WHERE expires_at < now() AND status <> 'in_progress';

-- Pending provider events.
SELECT provider, count(*)
FROM payment_events
WHERE status = 'received'
GROUP BY provider;
```

Page on the first query returning any row, on a failed migration, on repeated
`IDEMPOTENCY_KEY_REUSED` spikes from one user, or on a callback signature
failure spike.

## 5. Backup and restore

- Production requires automated daily backups **and** point-in-time recovery.
- Test a restore at least quarterly into an isolated database. After restore:
  1. run `npm run verify`;
  2. compare `schema_migrations` with the expected release list;
  3. run the ledger checks above;
  4. confirm the restored database cannot be reached by the production API.
- Backups must be encrypted at rest and in transit.
- The desktop snapshot of this repository is a development backup, not a
  production database backup. It contains no real customer data.

## 6. Encryption

- `DATA_ENCRYPTION_KEY` is a 32-byte base64 key in the hosting secret manager.
- It encrypts KYC identifiers, recipient destinations, trade recipient
  snapshots and idempotency response bodies.
- Losing the key makes restricted fields unreadable. Rotating it requires a
  controlled re-encryption job; no rotation job is implemented in B1.
- Never log the key, ciphertext, plaintext KYC identifier or a recipient account
  number.

## 7. Incident playbooks

### A provider webhook arrives twice

1. `payment_events (provider, provider_event_id)` is unique; the second insert
   is rejected before any ledger effect.
2. If a ledger posting is attempted twice, `journal_transactions.posting_key`
   is unique; the second posting is rejected.
3. Do not delete the duplicate event. Mark it `ignored` and retain the audit.

### Two `trade/initiate` requests race

1. Both use the same `(user_id, scope, key)`.
2. The first transaction inserts `in_progress`; the second waits on the unique
   index.
3. If the first commits, the second replays the stored response.
4. If the first rolls back, the second acquires the key and proceeds.
5. Never delete an in-progress row to "unblock" a request; investigate the
   transaction that owns it.

### A quote appears consumed without a trade

1. Inspect `quotes.consumed_at` and the transaction that consumed it.
2. Check for a crashed transaction that updated the quote without inserting the
   trade; atomicity should have rolled it back.
3. Do not reactivate a quote. Issue a new quote and record the incident.

### An illegal trade transition is attempted

1. The database rejects it with `illegal trade transition from -> to`.
2. Inspect `trade_status_transitions` and the service mapping.
3. Add the transition only after Product and Compliance approve the workflow.
   Never update an existing trade status directly in production.

### Ledger imbalance

1. Treat it as a production incident.
2. Stop financial write traffic if the imbalance can grow.
3. Identify the transaction from `journal_transaction_balances`.
4. Do not edit or delete lines. Post a reversing transaction after the cause is
   understood and approved by Finance.
5. Preserve the database audit trail and notify Finance/Legal.

## 8. Data retention

Provisional settings are in `server/.env.example`:

- `KYC_RETENTION_DAYS=2555` (seven years) until Legal approves a per-market
  policy.
- Deleted users and recipients are soft-deleted. Hard delete requires an
  approved retention and erasure procedure.
- Idempotency keys default to 24 hours; responses containing personal data are
  encrypted and pruned.
- Ledger and trade-event rows are never deleted as part of normal operations.

## 9. Release checklist

- [ ] `npm run typecheck` passes.
- [ ] `npm test` passes against a fresh embedded PostgreSQL.
- [ ] `npm run migrate` applies cleanly to a staging snapshot.
- [ ] `npm run seed` is idempotent on staging.
- [ ] `npm run verify` reports `ok: true`.
- [ ] Backup/PITR confirmed before a production migration.
- [ ] Ledger checks return zero rows.
- [ ] No secrets, `.env` files or customer data are staged.
- [ ] Finance/Legal approvals recorded for any new ledger account or posting.
