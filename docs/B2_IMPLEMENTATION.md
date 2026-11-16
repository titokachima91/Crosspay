# B2.0 implementation record — HTTP bootstrap

**Program**: CrossPay — PART 2 Backend
**Workstream**: B2.0 — Bootstrap API on the B1 data foundation
**Status**: Built and verified 2026-11-15
**Depends on**: `docs/B1_IMPLEMENTATION.md`, `docs/api_contract.md`
**Code**: `server/src/http/`, `server/test/http-bootstrap.test.ts`
**Next records**: `docs/B2_2_IMPLEMENTATION.md` (rates, estimate and quote),
`docs/B2_3_B2_4_IMPLEMENTATION.md` (collections, payouts, refunds, callbacks),
`docs/OTP_WIRING_PLAN.md` (HTTP SMS adapter and provisional sender)

---

## 1. Scope delivered

B2.0 covers the endpoints the app needs to get past splash and sign-in, plus
saved recipients. It does not invent pricing, SMS delivery or name-check data.

| Endpoint | Delivered behaviour |
|---|---|
| `GET /health` | Process and database liveness |
| `GET /api/v1/config` | Five ordered lists, payout-rail `kind`, optional support |
| `POST /api/v1/auth/otp/request` | Rate-limited code creation; real SMS adapter required |
| `POST /api/v1/auth/otp/verify` | Code verification, user creation, access + refresh tokens |
| `POST /api/v1/auth/refresh` | Rotation, family revocation on reuse |
| `GET /api/v1/me` | Profile, tier, limit currency and derived daily usage |
| `PUT /api/v1/me/kyc` | Encrypted KYC submission, status `pending` |
| `GET /api/v1/beneficiaries` | Owner-only list, decrypted only for the owner |
| `POST /api/v1/beneficiaries` | Idempotent create, validation, duplicate protection |
| `PATCH /api/v1/beneficiaries/{id}` | Idempotent update, ownership check |
| `DELETE /api/v1/beneficiaries/{id}` | Idempotent soft delete, replay-safe |
| `POST /api/v1/beneficiaries/check` | Honest `503 NAME_CHECK_NOT_CONFIGURED` |
| `GET /api/v1/rates` | Honest `503 PRICING_NOT_CONFIGURED` |
| `GET /api/v1/market/depth` | Honest `503 MARKET_DATA_NOT_CONFIGURED` |
| `POST /api/v1/trade/*` | Honest `503 PRICING_NOT_CONFIGURED` (B2.0); B2.2 now serves estimate and quote, initiate remains `503 PAYOUT_NOT_CONFIGURED` |
| `GET /api/v1/trades*` | Honest `503 TRADING_NOT_CONFIGURED` |

Everything else returns a structured 404. Protected routes require a Bearer
access token; the public surface is `/health`, `/config`, `/rates`, the OTP
endpoints and `/auth/refresh`.

---

## 2. Authentication

- B2.0 reuses the B1 OTP supersession columns and refund guard; no applied
  migration is edited after release.
- Access token: HS256 JWT, issuer `crosspay-api`, audience `crosspay-app`,
  subject = user id, default lifetime 15 minutes.
- Refresh token: 32 random bytes, stored only as a SHA-256 hash, default
  lifetime 30 days, rotated on every use.
- A rotated token that is presented again revokes the whole family in the same
  transaction and returns `401 REFRESH_TOKEN_REUSED`.
- A successful OTP creates the user (phone verified) or reuses an existing
  active user. A soft-deleted account is refused with `403 ACCOUNT_DISABLED`.
- `profileComplete` is true once a legal name and a KYC submission exist;
  rejected/pending both enter Home, verified can trade.
- PIN and biometric data never reach the server.

## 3. OTP and rate limiting

- Six-digit code, five-minute expiry, five attempts per code.
- A new code supersedes older unused codes for the same phone.
- Codes are stored as HMAC-SHA-256 hashes only.
- Fixed-window limits in PostgreSQL, shared across API instances:
  - five code requests per phone per 15 minutes;
  - thirty code requests per source IP per 15 minutes;
  - ten verification attempts per phone per 15 minutes;
  - fifty verification attempts per source IP per 15 minutes;
  - sixty refresh attempts per source IP per 15 minutes.
- When no SMS partner is configured, the request returns
  `503 SMS_NOT_CONFIGURED` and the unsent challenge is superseded. The server
  never logs or returns the code.

## 4. KYC submission

`PUT /api/v1/me/kyc`:

1. Rejects a second pending/verified submission.
2. Validates the trading hub for business accounts.
3. Resolves the limit currency from the hub country, or from the longest
   matching phone dial code for personal accounts.
4. Encrypts the ID/TIN with AES-256-GCM, stores an HMAC hash and last four
   characters only, and rejects an identity already linked to another account.
5. Sets the user to `pending`. A real KYC provider or manual reviewer is a
   later integration; the status is honest.

The full identifier is never returned by `/me` and never logged.

## 5. Limits and daily usage

- `/me` reads `tier_limits` for the user’s tier and limit currency.
- If no approved limit exists, `dailyLimitMinor` is `0`. This is conservative,
  not an invented amount.
- `dailyUsedMinor` is derived from trades created in the current day in
  `LIMIT_TIMEZONE` (default UTC), excluding `cancelled`, `expired` and `failed`.
- No wallet or stored balance exists.

## 6. Saved recipients

- All writes require `X-Idempotency-Key`.
- Same key + same body replays the original status/body with
  `Idempotency-Replay: true`.
- Same key + different body returns `409 IDEMPOTENCY_KEY_REUSED`.
- A concurrent duplicate waits on the database unique key; one result wins.
- Ownership is enforced in every query. A non-owner gets 404.
- Destinations are normalised, encrypted, HMAC-hashed and protected by a partial
  unique index.
- Delete is a soft delete. A repeated same-key delete replays 204.

## 7. Security controls

- Fastify logger redacts `Authorization` and `X-Idempotency-Key`; no route logs
  a request body.
- Errors never expose stack traces or SQL. Unexpected failures return
  `{ error: { code: "INTERNAL_ERROR", message: "Unexpected server error" } }`.
- JSON body limit is 1 MiB.
- CORS is disabled unless `CORS_ORIGINS` names explicit web origins.
- `trustProxy` is enabled so rate limiting uses the client address behind the
  Render proxy.
- Public routes are an explicit allow-list; new routes are authenticated by
  default.
- Database queries are parameterised; no string interpolation of user input.

## 8. Verification

```sh
npm run typecheck
npm run build
npm test
```

Result on 2026-11-15: typecheck and build clean, **36/36 tests pass**, 8 suites,
against embedded PostgreSQL 17. `npm run verify:local` reports `ok: true` with
7 migrations and the unchanged B1 reference counts. The HTTP file adds:

- `/config` shape and `503` states for rates and unauthenticated access;
- OTP request, wrong code, correct code and session shape;
- `/me` blocked before KYC, then returned with `pending`, TZS and zero limit;
- recipient create, replay, different-body conflict, list, update and delete;
- refresh rotation and family revocation;
- per-phone rate limit returning `429`;
- the `SMS_NOT_CONFIGURED` path proving no code is returned when delivery is
  disabled.

No frontend files changed.

## 9. What remains

| Item | Why it is not built |
|---|---|
| Real SMS delivery | HTTP `SmsSender` adapter built; a partner/gateway and per-market sender approval are still required |
| Live rates / estimate / quote | Built in B2.2 against the sandbox reference provider; a real pricing source still needs Product/Finance approval |
| Name check | Needs a payout-provider name-match API |
| Trade initiation and list/history/analytics/export | Needs the B2.3 collection lifecycle and the provider flow |
| Invoice/share | Signed URL policy and verification-hash ownership |
| Payment webhooks, payouts, refunds | B3; provider contracts and signing keys |
| KYC provider | Partner selection, retention and data-residency decision |
| Tier limits | Product/Finance approval |

The next engineering step is a real SMS adapter behind `SmsSender`, then the
pricing provider behind the existing quote and trade tables.

---

## 10. Files

```
server/src/http/
  auth.ts              JWT sign/verify and Bearer extraction
  context.ts           Request-scoped dependencies
  errors.ts            AppError and HTTP helpers
  idempotent-route.ts  Transactional idempotency wrapper
  server.ts            Fastify assembly, secure-by-default hook, error mapping
  start.ts             Environment loading and process lifecycle
  validation.ts        Zod body parsing
  routes/
    auth.ts            OTP and refresh
    beneficiaries.ts   Recipient CRUD
    config.ts          GET /config
    me.ts              GET /me and PUT /me/kyc
    unavailable.ts     Honest 503 endpoints
server/src/providers/sms.ts
server/src/services/rate-limit.ts
server/src/services/users.ts
server/test/http-bootstrap.test.ts
server/test/helpers/fake-sms.ts
```
