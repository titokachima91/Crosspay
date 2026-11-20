# CrossPay runbook

This is the operator's first stop. It covers the actual commands, ports and
failure modes used to run the app, the API, the admin portal, the worker and the
sandbox. Feature contracts live in `docs/api_contract.md`; this file is for
"how do I run and recover it".

If a command here disagrees with the code, fix this file in the same change.

---

## 1. Start here

### 1.1 The three runtimes

| Runtime | What it serves | Where |
|---|---|---|
| Flutter app | The customer app; preview build uses `preview/` fixtures | `lib/`, `preview/` |
| CrossPay API + admin + worker | Production-shaped backend, PostgreSQL | `server/` |
| Kachi sandbox | Provider simulator and a CrossPay-compatible `/api/v1` facade | separate sandbox repo |

The customer app does **not** contain a database. It reads `/config` and
`/rates` first, then `/auth/*`, `/me`, trades, etc. If the app cannot reach a
server, splash stops with an honest error.

### 1.2 The API base URL is compiled in

`AppConstants.apiBaseUrl` comes only from:

```bash
--dart-define=API_BASE_URL=http://<host>:<port>
```

An APK built without that define can never get past splash, even when a sandbox
is running. The value is embedded in the APK, not read from a settings screen.
If the host or port changes, rebuild the APK.

For the current LAN sandbox the sideload build uses the dev-OTP instance on
`:8081`, so sign-in works without a real SMS gateway:

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=http://192.168.1.17:8081
```

`:8080` remains the normal sandbox on real SMS; it can serve splash/config and
rates, but its OTP path returns 503 unless the local gateway is running. See
section 4.

### 1.3 Which backend should the app point at?

| Goal | Point `API_BASE_URL` at |
|---|---|
| Sandbox demo with sign-in | Dev-OTP sandbox, normally `:8081` |
| Sandbox splash/config only | Normal sandbox, normally `:8080` |
| Production-shaped local API | CrossPay API, normally `:3000` |
| Preview web without a server | `flutter run -t preview/main.dart` (uses overrides) |

Both sandbox ports implement the same `/api/v1` shapes. If `:8081` shares the
`:8080` SQLite database, institutions/accounts created in the normal sandbox are
visible to the dev-OTP app. Do not assume `:3000` is CrossPay; check the process
first (on this Mac it has been used by another project).

---

## 2. Current local topology (check, never assume)

```bash
lsof -nP -iTCP -sTCP:LISTEN | sort -k9
```

Known services and their usual ports:

| Service | Port | Start command |
|---|---|---|
| CrossPay API | 3000 | `cd server && npm run dev` |
| Admin portal | 3001 | `cd server && npm run admin:dev` |
| Local dev PostgreSQL | 55432 | `cd server && npm run dev:db` |
| Kachi sandbox | 8080 | sandbox repo: `node server.js` |
| APK file share | 8765 (example) | `python3 -m http.server 8765 --bind 0.0.0.0 --directory <dir>` |
| Chrome remote debug | 9222 | Chrome with `--remote-debugging-port=9222` |

Never bind a fixed port without checking it:

```bash
lsof -nP -iTCP:8765 -sTCP:LISTEN && echo "busy" || echo "free"
```

### 2.1 Health checks

```bash
# CrossPay API
curl -s http://127.0.0.1:3000/health

# Admin portal
curl -s http://127.0.0.1:3001/health

# Sandbox (CrossPay facade)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/v1/config
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/v1/rates

# From a phone, use the Mac LAN address, e.g.
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.17:8080/api/v1/config
```

`/config` and `/rates` must both be `200` before blaming the app.

---

## 3. Local development from zero

### 3.1 Prerequisites

- Flutter 3.24+ and Dart
- Node 22+
- Xcode only for iOS; Android SDK 35 for Android
- No Docker required for the default dev loop

### 3.2 Server

```bash
cd server
npm ci
cp .env.example .env
# Fill DATABASE_URL, DATA_ENCRYPTION_KEY, JWT_SECRET and providers.
# Generate a 32-byte base64 key:
openssl rand -base64 32
```

### 3.3 Persistent local PostgreSQL

```bash
cd server
npm run dev:db        # embedded cluster on 127.0.0.1:55432
```

- Data directory: `server/.devdb` (gitignored).
- Applies migrations and seed on start.
- Keep the process running; `Ctrl-C` stops it without deleting data.
- Reset from scratch:

```bash
# stop dev:db first
rm -rf server/.devdb
npm run dev:db
```

Connection string used by the dev scripts:

```text
postgres://postgres:postgres@127.0.0.1:55432/postgres
```

### 3.4 API, admin and worker

```bash
cd server
npm run dev            # API :3000
npm run admin:dev      # admin :3001
npm run worker         # reconciliation loop
```

For one worker pass:

```bash
WORKER_ONCE=true npm run worker
```

### 3.5 Flutter

```bash
flutter pub get

# Against a local server, from an emulator:
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000

# Against the sandbox from a physical phone on the same Wi-Fi:
flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8080
```

Get the Mac LAN IP:

```bash
ipconfig getifaddr en0
```

The splash needs `/config` and `/rates`. The app shows an honest error instead
of invented data when either fails.

---

## 4. Sandbox operations

The sandbox is a separate provider simulator. It owns its own SQLite database
and also exposes a CrossPay-compatible `/api/v1` facade.

### 4.1 Run the normal sandbox

The current working copy is outside this repo (find it before running):

```bash
# example working copy
cd ~/.cline/data/workspaces/chat/kachi-fintech-sandbox
node server.js
```

Health:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/v1/config
```

Do not modify its GasLink keys/routes, SMS/AI files or SQLite data unless the
task explicitly requires it.

### 4.2 OTP modes

The sandbox has two sign-in paths:

| Mode | Environment | Behaviour |
|---|---|---|
| Real SMS | `FACADE_SMS_DELIVERY=true` | Calls the configured gateway. If the gateway is down, OTP request returns `503 SMS_DELIVERY_FAILED`. |
| Dev OTP | `FACADE_SMS_DELIVERY=false` + `FACADE_DEV_OTP=true` | Stores the code, returns normally and exposes it through sandbox state. |

The active `:8080` instance is normally on real SMS. The local gateway is not
always running, so OTP can fail even though config/rates work.

### 4.3 Isolated dev-OTP instance for app testing

Use a copy of the SQLite database when the main instance must keep real SMS:

```bash
cd <sandbox>
cp data/kachi-sandbox.db /tmp/kachi-app-test.db
PORT=8081 \
SANDBOX_DB_PATH=/tmp/kachi-app-test.db \
FACADE_SMS_DELIVERY=false \
FACADE_DEV_OTP=true \
node server.js
```

Then point the app at `http://<mac-lan-ip>:8081` and rebuild the APK.

To share the live data instead of a copy, start without workers:

```bash
PORT=8081 \
FACADE_SMS_DELIVERY=false \
FACADE_DEV_OTP=true \
node -e "require('./server').start(8081,{startWorkers:false})"
```

Sharing SQLite is supported by WAL mode but is only for local testing; do not
run two production-like sandboxes on one database. The current `:8081` instance
for the biometric test uses this shared-database form.

### 4.4 Retrieve the OTP code

Two ways:

1. Open `http://<mac-lan-ip>:8081/dashboard` on the phone or Mac, paste the
   sandbox API key once (the value of `SANDBOX_API_KEY_CROSSPAY` in the sandbox
   `.env`), and read the pending OTP under **OTP codes**.
2. Or query state with the key:

```bash
curl -s http://127.0.0.1:8081/api/v1/sandbox/state \
  -H "x-api-key: $SANDBOX_API_KEY_CROSSPAY" \
  | python3 -m json.tool | grep -A4 '"phone"'
```

Find the phone you entered, copy its `code`, and type it into the app. The app
does not display sandbox codes; that is deliberate, because they are test data.

### 4.5 Institutions and accounts

Create them manually through the sandbox dashboard/API. The app only reads what
exists; there is no hardcoded institution list in `lib/`.

### 4.6 Live contract test

```bash
cd crosspay_app
LIVE_SANDBOX=1 \
LIVE_SANDBOX_URL=http://127.0.0.1:8081 \
LIVE_SANDBOX_KEY=<sandbox-crosspay-key> \
flutter test test/live_sandbox_test.dart
```

The test creates a fresh phone and NIN. It needs the dev-OTP mode above.

---

## 5. Builds and APK serving

### 5.1 Web preview

```bash
flutter build web --release -t preview/main.dart
```

The preview uses `preview/` overrides and does not require the API. It is for UI
checks only; it is not a connected app.

### 5.2 Debug APK

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=http://<mac-lan-ip>:8080
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`.

Verify the baked URL before sharing:

```bash
unzip -p build/app/outputs/flutter-apk/app-debug.apk \
  assets/flutter_assets/kernel_blob.bin | grep -a 'http://<mac-lan-ip>:8080'
```

Debug builds allow cleartext HTTP through the debug manifest. A release build
over HTTP needs an explicit network-security policy; production must use HTTPS.

### 5.3 Install

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Or download from the Mac:

```bash
mkdir -p /tmp/crosspay-apk
cp build/app/outputs/flutter-apk/app-debug.apk /tmp/crosspay-apk/
lsof -nP -iTCP:8765 -sTCP:LISTEN && echo busy || echo free
python3 -m http.server 8765 --bind 0.0.0.0 --directory /tmp/crosspay-apk
```

Phone URL: `http://<mac-lan-ip>:8765/app-debug.apk`.

If the phone cannot connect: check both devices are on the same Wi-Fi, the Mac
firewall allows Python/node, and the server is bound to all interfaces
(`--bind 0.0.0.0`). Re-check `/config` from the phone browser first.

### 5.4 Biometric smoke test

1. Sign in, open **Account → Security**.
2. Set a 4–6 digit PIN. Biometrics start off.
3. Enable **Biometric unlock**; the device prompt must succeed.
4. Tap **Test biometrics now**.
5. Tap **Lock app now**: biometric prompt appears. Cancel → PIN dialog.
6. Background the app and reopen it: it locks and asks for biometrics/PIN, not
   OTP. The session and refresh token are retained.
7. Turn the PIN off: the lock and biometric preference are cleared.
8. **Sign out** separately: the refresh-token family is revoked, local tokens
   and the device PIN/biometric preference are cleared, and the next sign-in
   needs a new OTP. That is intentional.
9. **Switch account** does the same and returns to the start screen; tap
   **Sign in** for the other number. The account model and deletion policy are
   in `docs/AUTH_FLOWS.md`.

If no biometric is enrolled, the switch is disabled with an honest message.
iOS/Face ID is unverified until Xcode is installed.

---

## 6. Tests and release gate

```bash
cd server
npm run typecheck
npm test                     # 122 tests, 21 suites
npm run build

cd ..
flutter analyze
flutter test                 # 236 passed, 1 skipped
flutter build web --release -t preview/main.dart
flutter build apk --debug --dart-define=API_BASE_URL=http://<host>:<port>
```

The skipped test is the opt-in live sandbox contract. Run it separately with
`LIVE_SANDBOX=1` as in section 4.6.

Do not claim a release from a partial run. Record the actual result in
`docs/BUILD_LOG.md`.

---

## 7. Database operations

### 7.1 Development

```bash
cd server
npm run migrate        # forward-only, checksum-locked
npm run seed
npm run dev:db         # start + migrate + seed
```

- Never edit an applied migration. Add a new numbered migration.
- A checksum mismatch is drift; stop and investigate.
- `npm run migrate` is idempotent and reports `applied` / `skipped`.

### 7.2 Backup and restore (dev cluster)

```bash
pg_dump 'postgres://postgres:postgres@127.0.0.1:55432/postgres' \
  -Fc > crosspay-dev-$(date +%F).dump

pg_restore --clean --if-exists \
  -d 'postgres://postgres:postgres@127.0.0.1:55432/postgres' \
  crosspay-dev-YYYY-MM-DD.dump
```

### 7.3 Production-like stack

```bash
cp server/.env.example server/.env   # fill secrets
export POSTGRES_PASSWORD='url-safe-password'
docker compose up --build
```

Full details: `docs/DEPLOYMENT.md`. Docker is not installed on this Mac, so the
compose stack has not been launched here; it has been YAML-checked and the
compiled entrypoints exercised.

---

## 8. Admin portal operations

- Login: password + TOTP; recovery code is the fallback, single-use.
- First admin: `npm run admin:create -- --email ... --name ... --role ...`.
  Printed TOTP secret and recovery codes are shown once.
- RBAC: viewer, ops, finance, compliance, superadmin. The last superadmin cannot
  be suspended.
- Configuration changes use propose → different admin approves. Emergency
  service controls are immediate and superadmin-only.
- Customer session reset is in Customer 360 under Support; requires
  `support:write` and a 5–300 character reason.
- Worker heartbeat is on the Overview. Missing >5 min is a warning; >15 min is
  critical. Start `npm run worker` if it is stale.
- Control room uses SSE + `LISTEN admin_activity`; do not put a buffering proxy
  in front of `/control-room/stream`.

Admin credentials are not stored in this repository.

---

## 9. Incident playbook

| Symptom | Check | Fix |
|---|---|---|
| Splash stuck / "not configured" | `API_BASE_URL` baked into the APK; sandbox `/config` + `/rates` | Rebuild APK with the current LAN URL; start the backend |
| Splash shows network error | Phone and Mac on same Wi-Fi; Mac firewall; correct IP | Bind `0.0.0.0`, allow the process, rebuild with the right host |
| OTP request `503 SMS_DELIVERY_FAILED` | Sandbox real-SMS gateway not running | Start the gateway or use a dev-OTP instance |
| OTP request `429 RATE_LIMITED` | Per-phone resend or sandbox in-process limiter | Wait for the window; use a fresh phone in tests |
| OTP asked on every app open | The person signed out, or the refresh token was cleared/revoked | Sign out is a full logout; use **Lock app now** or backgrounding for biometric/PIN re-entry |
| "Get started" shown to a returning user | No stored refresh token, or session restore failed and tokens were cleared | Check sign-out history and network; the splash shows Continue instead when a token exists |
| Admin redirects to `/login` | Session cookie expired/revoked | Sign in again with TOTP |
| Admin form `403 ADMIN_CSRF_INVALID` | Page was open across a restart | Reload the form and submit |
| Worker KPI "never" or stale | Worker process stopped | `cd server && npm run worker`; check DB |
| Migration checksum error | An applied migration was edited | Restore the original file, add a new migration |
| `EADDRINUSE` | Another process on the port | `lsof -nP -iTCP:<port> -sTCP:LISTEN` |
| Refresh token rejected | Rotation reuse/expiry | Sign in again; expected terminal path |
| `SESSION_REVOKED` on a device | A newer OTP sign-in replaced this session (one active session per account) | Sign in again with OTP; this is expected |
| APK installs old build | Browser/Android cache | Uninstall, use `adb install -r`, rename the file |
| Live sandbox test fails at OTP | Real-SMS sandbox | Use dev-OTP instance and matching key |
| Admin layout/SSE stalls | Buffering proxy | Disable proxy buffering for SSE |

---

## 10. Snapshots, git and release

1. Run the release gate in section 6.
2. Commit code and docs together.
3. Create a timestamped snapshot under `~/Desktop/Projects/CrossPay/` with
   `rsync`, excluding `node_modules`, `build`, `.dart_tool`, `server/.devdb`,
   `server/.env`, `server/dist`, `server/coverage`.
4. Write `SNAPSHOT_INFO.txt` with commit, file count, size and verified results.
5. `git -C <snapshot> fsck --no-dangling`, confirm the worktree is clean.
6. Push the branch; open a PR. Never push `main` without explicit approval.
7. Update `MASTER_PROGRESS_REPORT.md` with the snapshot path and commit.

Snapshot is a copy, not a backup of provider secrets or `.env`. Back up
`DATA_ENCRYPTION_KEY` and `JWT_SECRET` separately.

---

## 11. Documentation map — update rules

| Change | Must update |
|---|---|
| API request/response/error code | `docs/api_contract.md` |
| Auth/account lifecycle | `docs/AUTH_FLOWS.md` |
| Product or technical decision | `docs/DECISIONS.md` |
| Schema/migration | `docs/B1_DATABASE_PLAN.md`, `docs/BUILD_LOG.md` |
| Admin page/action/RBAC | `docs/ADMIN_WEB_IMPLEMENTATION.md` |
| Deployment/ports/env | `docs/RUNBOOK.md`, `docs/DEPLOYMENT.md` |
| Flutter screen/behavior | `README.md` if setup changes, `docs/BUILD_LOG.md` |
| Test count/verification | `MASTER_PROGRESS_REPORT.md`, `docs/BUILD_LOG.md` |
| Snapshot | `MASTER_PROGRESS_REPORT.md`, `SNAPSHOT_INFO.txt` |

If a runbook command stops being true, it is a bug. Fix it in the same commit as
the code that changed it.

---

## 12. Non-negotiables

- No hardcoded operational data in `lib/`; server is the source of truth.
- Amounts are minor units; never sum or compare across currencies.
- CrossPay does not hold customer cash.
- No direct SQL, ledger edits, "mark as paid", bulk PII export or bypassing KYC
  from the admin portal.
- Control-room activity never carries names, phone numbers, account numbers,
  case bodies or ID numbers.
- Sandbox GasLink keys/routes/data and protected SMS/AI files are not part of the
  app and are not modified without an explicit task.
- Do not push `main` or publish a release without explicit confirmation.
