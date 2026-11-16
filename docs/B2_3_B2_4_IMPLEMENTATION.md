# B2.3 collections and B2.4 payouts, refunds and callbacks

**Status**: built and verified 2026-11-16.
**Code**: `server/src/trades.ts`, `server/src/payments.ts`,
`server/src/webhooks.ts`, `server/src/http/routes/trades.ts`,
`server/src/http/routes/payments.ts`, `server/src/http/routes/webhooks.ts`
**Tests**: `server/test/trades.test.ts`,
`server/test/payment-operations.test.ts`
**Live smokes**: `npm run smoke:b2.3`, `npm run smoke:b2.4`,
`npm run smoke:webhooks`

---

## 1. What B2.3 delivers

`POST /api/v1/trade/initiate` is the one write that turns a quote into money
movement. In one idempotent transaction it:

1. loads the signed-in user and requires `verified` KYC;
2. consumes the quote (`active -> consumed`, never twice);
3. re-checks the daily limit in the quote's send currency;
4. checks the route and recipient rail belong to the quote;
5. snapshots the encrypted recipient account, last four and optional reference;
6. creates the trade and one payment attempt;
7. calls `createCollection` with the deterministic `CP-...` reference;
8. applies the provider's initial status and returns collection instructions.

The deterministic reference is the provider idempotency key. If the database
transaction rolls back after the provider accepted the request, retrying with
the same quote produces the same reference and the provider returns its
original collection instead of starting a second charge.

Read/manage routes:

| Route | Behaviour |
|---|---|
| `GET /trades` | newest first, scoped to the signed-in user |
| `GET /trades/:id` | polling target |
| `GET /trades/:id/history` | append-only status timeline |
| `POST /trades/:id/payment-claim` | re-reads the provider; never marks paid by itself |
| `POST /trades/:id/cancel` | only from `pending_deposit`; `ALREADY_PAID` after provider confirmation |

A late provider success after cancellation is booked (deposit + net fee) and
then refunded, so the money is never invisible and the trade stays `cancelled`.

---

## 2. What B2.4 delivers

### 2.1 Payout

`POST /api/v1/trades/:id/disburse` starts or resumes one payout:

- only `escrowed`, `matching`, `matched` or `disbursing` trades;
- mobile-money rails only; a bank rail is an honest
  `503 PAYOUT_RAIL_NOT_CONFIGURED` until an approved partner account exists;
- the trade takes the generic `escrowed -> matching -> matched` path so the
  later P2P engine can replace direct liquidity without changing the saga;
- one `payouts` row survives retries; the provider reference is
  `<trade reference>-OUT`;
- a retry reads the existing provider payout instead of creating another;
- `202` means pending/submitted, `200` means terminal.

A provider rejection refunds the payer before the error is returned. A
provider outage leaves the trade retryable.

### 2.2 Payout ledger

Success posts three journals, each single-currency and balanced:

| Journal | Debit | Credit | Currency |
|---|---|---|---|
| FX source | `2000` trade payable | `5000` FX clearing | send |
| FX destination | `5000` FX clearing | `2000` trade payable | receive |
| Payout | `2000` trade payable | `1000` partner trust cash | receive |

The two FX journals share `fx_group_id = payout.id`. Minor units are never
summed across currencies; the clearing account is only a bridge. A provider
payout fee, when present, is a `6000` provider-fee expense in the payout
journal, never an invented cash difference.

### 2.3 Refund

`POST /api/v1/trades/:id/refund`:

- requires a confirmed collection and no payout;
- asks the provider first and validates amount and currency;
- records `refunds` with a deterministic provider request;
- reverses the deposit and fee journals as `refund_paid`;
- moves the trade to `refunded`, except a late-paid cancelled trade that stays
  `cancelled`;
- refuses with `PAYOUT_ALREADY_SENT` after a completed payout (a payout
  clawback is a dispute flow, not a refund).

A payout failure or rejection calls the same refund path.

### 2.4 Signed callbacks

`POST /api/v1/webhooks/payments/:provider` is public, but the HMAC is the
authentication:

- `X-Kachi-Timestamp` must be within `PAYMENT_WEBHOOK_MAX_SKEW_SECONDS`;
- `X-Kachi-Signature` is HMAC-SHA256 over `<timestamp>.<exact raw body>`;
- the raw body is kept by a custom JSON parser, never re-serialised;
- signature comparison is constant-time;
- `(provider, provider_event_id)` is unique in `payment_events`;
- a replay returns `200 { received: true, replay: true }` and moves no money;
- a failed mid-flight event stays `received`, so a provider retry can resume;
- the provider status is re-read and amount/currency validated before booking.

Collection callbacks use `checkoutRequestId`; payout callbacks use `payoutId`.
The shared collection application is used by both the app claim route and the
webhook, so the two paths cannot drift.

---

## 3. Error contract

| Situation | Result |
|---|---|
| quote expired/consumed | `409 QUOTE_EXPIRED` / `409 QUOTE_NOT_ACTIVE` |
| limit exceeded | `422 LIMIT_EXCEEDED` |
| rail/route mismatch | `422 RECIPIENT_REJECTED` |
| provider rejects | provider 4xx code |
| provider down/malformed | `503 PAYMENT_PROVIDER_UNAVAILABLE` / `..._INVALID_RESPONSE` |
| payment provider disabled | `503 PAYOUT_NOT_CONFIGURED` |
| payout provider rejects | provider 4xx code, after the refund |
| bank payout not connected | `503 PAYOUT_RAIL_NOT_CONFIGURED` |
| refund after payout | `409 PAYOUT_ALREADY_SENT` |
| bad webhook signature | `401 WEBHOOK_SIGNATURE_INVALID` |
| stale webhook | `401 WEBHOOK_TIMESTAMP_INVALID` |
| webhook secret absent | `503 WEBHOOKS_NOT_CONFIGURED` |

No endpoint returns a fake success. The Flutter app can rely on the honest
`503` states.

---

## 4. Live verification

The sandbox was running at `http://127.0.0.1:8080` with mock APIs enabled.

**`smoke:b2.3`** — 1,000,000 TZS minor:

- real sandbox quote: rate `17.499956`, fee `15,000 TZS` (150 bps);
- sandbox collection: `1,015,000 TZS`, provider fee `10,150 TZS`;
- claim result: `escrowed`;
- deposit + fee journals balanced;
- cash `1,004,850 TZS`, payable `-1,000,000 TZS`, net fee revenue
  `-4,850 TZS`.

**`smoke:b2.4`** — same corridor, KES payout:

- receive amount `5,714,300 KES` minor;
- sandbox KES payable funded with an unrelated KES collection (test liquidity);
- payout `SUCCESS`, trade `completed`;
- journals: deposit/fee in TZS; FX source TZS; FX destination KES; payout KES;
- FX source `-1,000,000 TZS`, FX destination `+5,714,300 KES`, each journal
  balances to zero, all ledger transactions globally balanced.

**`smoke:webhooks`** — real signed deliveries:

- CrossPay listened on a loopback port with
  `PAYMENT_CALLBACK_URL=.../api/v1/webhooks/payments/sandbox`;
- sandbox delivered `psp.collection.success` and `psp.payout.success`;
- both `payment_events` rows are `processed` and `signature_verified`;
- trade reached `completed` without a manual claim.

Unit/integration suite: **74/74**, 15 suites, `npm run typecheck` clean.

---

## 5. Deliberate limits

- Bank payouts are not connected; only mobile-money payouts are live.
- There is no scheduler yet: pending payouts/refunds are resumed by an explicit
  `disburse` retry or provider callback. The primitives are idempotent.
- The P2P matching engine is not built. B2.4 takes the direct-liquidity path and
  exposes the saga the engine will call.
- The sandbox is a simulator. Its KES payable had to be funded before a KES
  payout; production uses an approved liquidity provider and never invents
  provider balances.
- Finance/Legal still need to approve the provisional chart of accounts,
  including the new `6000 Provider fees` expense.
- `fx_group_id` links two journals; reporting must read each currency
  separately and never sum minor units across currencies.
