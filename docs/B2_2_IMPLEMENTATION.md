# B2.2 implementation record — rates, estimate and quote

**Program**: CrossPay — PART 2 Backend
**Workstream**: B2.2 — Priced quotes on the B1 trading foundation
**Status**: Built and verified 2026-11-15
**Depends on**: `docs/B2_IMPLEMENTATION.md`, `docs/api_contract.md`
**Code**: `server/src/providers/pricing.ts`, `server/src/http/routes/pricing.ts`,
`server/src/quotes.ts`, `server/test/pricing.test.ts`,
`server/test/pricing-provider.test.ts`
**Provider reference**: `kachi-fintech-sandbox/docs/FACADE.md`

---

## 1. Scope delivered

| Endpoint | Delivered behaviour |
|---|---|
| `GET /api/v1/rates` | Provider rates with the contract's `from`/`to`/`rate`/`status` shape |
| `GET /api/v1/trade/estimate` | Provider estimate for a signed-in user; no quote, no lock |
| `POST /api/v1/trade/quote` | KYC/limit checks, provider pricing, durable quote + route snapshot |

B2.2 deliberately stops before initiation and payment. `POST /trade/initiate`
still returns an honest `503 PAYOUT_NOT_CONFIGURED`; B2.3 owns collection
attempts, and B2.4 owns payouts and refunds.

## 2. Provider boundary

`server/src/providers/pricing.ts` defines the `PricingProvider` interface and
two implementations:

- `DisabledPricingProvider` — the default. Every call returns
  `503 PRICING_NOT_CONFIGURED`; no rate is invented.
- `SandboxPricingProvider` — the reference provider. It calls the sandbox's
  provider-only endpoints:

| Sandbox endpoint | Auth | Purpose |
|---|---|---|
| `GET /api/v1/rates` | none | corridor rates and status |
| `GET /api/v1/sandbox/pricing/estimate` | `x-api-key` | indicative estimate |
| `GET /api/v1/sandbox/pricing/quote` | `x-api-key` | rate, fee, route availability and lock window |

The sandbox pricing routes are userless and read-only. The CrossPay API owns
the user, the quote row, limits and idempotency, so a provider outage cannot
consume a quote or a limit. Provider responses are validated with Zod; a
malformed response becomes `503 PRICING_UNAVAILABLE`, never a zero rate.

## 3. Quote persistence

`createQuote` in `server/src/quotes.ts` writes one `quotes` row and its
`quote_routes` snapshot in a single transaction. Before writing, it checks:

- positive amount and rate;
- `expiresAt > quotedAt`;
- one route per type, at most one recommendation;
- an unavailable route is never recommended;
- `totalDebitMinor = sendAmountMinor + feeMinor`;
- estimates are ordered.

The response is the contract shape:

```json
{
  "id": "<uuid>",
  "rate": 0.057143,
  "serverTime": "2026-11-15T...Z",
  "expiresAt": "2026-11-15T...Z",
  "routes": [
    {
      "route": "p2p",
      "feeBps": 150,
      "feeMinor": 1500,
      "payoutMinor": 17500,
      "totalDebitMinor": 101500,
      "estimatedMinSeconds": 20,
      "estimatedMaxSeconds": 60,
      "isRecommended": true,
      "isAvailable": true,
      "status": { "code": "active_clearing", "level": "healthy" },
      "breakdown": [{ "code": "platform_fee", "amountMinor": 1500 }]
    }
  ]
}
```

Fees are added on top; the payout is the full converted amount.

## 4. Users, KYC and limits

- Estimate requires a valid access token and an active user.
- Quote requires `kyc_status = 'verified'`; otherwise `403
  VERIFICATION_REQUIRED`.
- `dailyUsedMinor` and the daily limit use the same source as `/me`.
- A quote is rejected with `422 LIMIT_EXCEEDED` when no approved limit exists
  for the user's limit currency, or when amount + used exceeds it.
- The limit is only enforced when the send currency equals the user's limit
  currency. A cross-currency limit needs an approved FX conversion and belongs
  to B2.3; the server does not invent one.
- Unknown currencies and same-currency pairs are rejected with
  `400/422 VALIDATION_FAILED` before the provider is called.

## 5. Errors

| Code | Status | Meaning |
|---|---|---|
| `PRICING_NOT_CONFIGURED` | 503 | no provider selected |
| `PRICING_UNAVAILABLE` | 503 | provider down, timed out or malformed |
| `CORRIDOR_UNAVAILABLE` | 422 | provider has no rate/rail for the pair |
| `VERIFICATION_REQUIRED` | 403 | KYC is not verified |
| `LIMIT_EXCEEDED` | 422 | no approved limit or above remaining limit |
| `VALIDATION_FAILED` | 400/422 | bad corridor, currency or amount |

## 6. Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PRICING_PROVIDER` | `disabled` | `disabled` or `sandbox` |
| `SANDBOX_PRICING_URL` | — | sandbox base URL, e.g. `http://127.0.0.1:8080` |
| `SANDBOX_PRICING_KEY` | — | sandbox operator key; falls back to `SANDBOX_API_KEY_CROSSPAY` |
| `PRICING_TIMEOUT_MS` | `5000` | provider request timeout |

Start the reference flow:

```bash
# 1. sandbox
cd kachi-fintech-sandbox
SANDBOX_API_KEY_CROSSPAY=live-sandbox-key PORT=8080 npm start

# 2. CrossPay API
cd crosspay_app/server
PRICING_PROVIDER=sandbox \
SANDBOX_PRICING_URL=http://127.0.0.1:8080 \
SANDBOX_PRICING_KEY=live-sandbox-key \
npm run dev
```

## 7. Verification

```bash
cd crosspay_app/server
npm run typecheck   # clean
npm run build       # clean
npm test            # 42/42 passing, 10 suites
```

New coverage:

- `test/pricing-provider.test.ts` drives `SandboxPricingProvider` against a
  local HTTP contract stub: paths, API key, query parameters, 422 rejection,
  503 outage and malformed payload.
- `test/pricing.test.ts` covers provider rates, the disabled default, estimate,
  quote persistence and route snapshot, KYC gate, daily limit, unknown
  currency, provider rejection/outage/invalid data, and confirms rejected
  quotes are not stored.

A live check against the real sandbox returned:

```
rates     KES→TZS 0.057143, active_clearing/healthy
estimate  rate 0.057143, payoutMinor 17500, p2p 20–60s
quote     feeBps 150, feeMinor 1500, totalDebitMinor 101500,
          p2p and bank available, 5-minute lock
```

## 8. What remains

| Item | Why it is not built |
|---|---|
| `POST /trade/initiate` | Needs a collection provider and payment attempt lifecycle (B2.3) |
| `GET /market/depth` | Needs a market-data source; sandbox has one, CrossPay does not proxy it |
| Real pricing source | Needs Product/Finance approval of spread and fee |
| Approved tier limits | Empty in the seed by design; quotes reject until inserted |
| Cross-currency limit conversion | Needs the B2.3 FX/payment decision |
| Payout/refund webhooks | B2.4 |

The sandbox remains the reference provider and the only end-to-end demo path
until those integrations exist.
