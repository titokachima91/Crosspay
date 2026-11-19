# Deployment

This is the code-side deployment path. Hosting, DNS, TLS termination, the
managed PostgreSQL instance and secret storage remain product-owner decisions.

## Container stack

`server/Dockerfile` builds one image used by three processes:

| Process | Command | Port |
|---|---|---|
| API | `node dist/http/start.js` (default) | 3000 |
| Admin portal | `node dist/admin-web/server.js` | 3001 |
| Reconciliation worker | `node dist/worker-main.js` | none |
| Migrations | `node dist/db/migrate-cli.js` | none |

`compose.yaml` at the repository root runs PostgreSQL 17, a one-shot migration
service, the API, the admin portal and the worker.

```bash
cp server/.env.example server/.env
# Fill DATABASE_URL placeholders, DATA_ENCRYPTION_KEY, JWT_SECRET and providers.
export POSTGRES_PASSWORD='url-safe-password'
docker compose up --build
```

The compose file overrides `DATABASE_URL` for every service to point at the
`db` service. The password is interpolated into that URL, so it must be
URL-safe. Use a root `.env` or exported variables for `POSTGRES_PASSWORD`,
`ADMIN_BASE_URL` and `ADMIN_COOKIE_SECURE`.

Create the first named admin once the database is migrated:

```bash
docker compose run --rm api node dist/admin-web/create-admin-cli.js \
  --email admin@example.com --name "Ada" --role superadmin
```

The password is read from `ADMIN_PASSWORD` when stdin is not a TTY. The TOTP
secret and recovery codes are printed once; store them offline. Run this as a
one-off job with the migrator role, never automatically on every API boot.

## Migrations

- `npm run migrate` uses `tsx` and the source tree (development).
- `npm run migrate:prod` runs the compiled `dist/db/migrate-cli.js` and is the
  container entrypoint for the one-shot `migrate` service.
- Migrations are idempotent; the service reports `applied` and `skipped`.
- The runtime process should use a least-privilege database role. Only the
  migration job needs DDL rights.

## Health and monitoring

- `GET /health` on the API and admin portal checks the database.
- The worker records every completed pass in `worker_heartbeats`. The admin
  overview shows the age and error count of the last pass; a stale or missing
  heartbeat raises an alert. Alert thresholds are 5 minutes (warning) and
  15 minutes (critical).
- The control room uses `LISTEN admin_activity` with a polling fallback. It
  holds one database connection while a stream is open.

## Backups

Use the managed PostgreSQL provider's point-in-time recovery where available.
For a self-hosted PostgreSQL:

```bash
docker compose exec -T db pg_dump -U crosspay -Fc crosspay > crosspay-$(date +%F).dump
docker compose exec -T db pg_restore --clean --if-exists -U crosspay -d crosspay < crosspay-YYYY-MM-DD.dump
```

Test a restore into a separate database before relying on it. The application
encryption key and `JWT_SECRET` must be backed up separately; a database dump
without them cannot decrypt KYC, recipient or idempotency data.

## Still required outside this repository

- Managed PostgreSQL, TLS, DNS and firewall/private hostname.
- SSO and the deployment-level IP allowlist/zero-trust layer.
- Real provider, bank, SMS, KYC and sanctions contracts.
- Push to a remote only after the product owner confirms.
