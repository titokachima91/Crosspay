# CrossPay payment adapters

**Status**: provider boundary, sandbox adapter, B2.3 collections and B2.4
payouts/refunds/webhooks built 2026-11-16.
**Code**: `server/src/providers/payments.ts`, `server/src/payments.ts`,
`server/src/webhooks.ts`
**Tests**: `server/test/payment-provider.test.ts`,
`server/test/payment-operations.test.ts`
**Sandbox provider primitives**: `kachi-fintech-sandbox`

---

## 1. Boundary

CrossPay owns the trade, collection instructions, payout orchestration,
idempotency, limits, ledger and matching. The provider only performs the local
collection, payout, refund or bank transfer and reports its own status.

The adapter interface is provider-shaped:

```ts
interface PaymentProvider {
  createCollection(input): Promise<PaymentCollection>;
  getCollection(id): Promise<PaymentCollection | null>;
  createPayout(input): Promise<PaymentPayout>;
  getPayout(id): Promise<PaymentPayout | null>;
  refund(input): Promise<PaymentRefund>;
  getBankAccount(ref): Promise<PaymentBankAccount | null>;
  transfer(input): Promise<PaymentBankTransfer>;
}
```

Two implementations:

- `DisabledPaymentProvider` — default; honest
  `PAYMENT_PROVIDER_NOT_CONFIGURED`.
- `SandboxPaymentProvider` — reference adapter over the sandbox provider
  primitives.

---

## 2. Sandbox mapping

| CrossPay adapter | Sandbox endpoint |
|---|---|
| `createCollection` | `POST /api/sandbox/psp/stk-push` |
| `getCollection` | `GET /api/sandbox/psp/requests/:id` |
| `createPayout` | `POST /api/sandbox/psp/payouts` |
| `getPayout` | `GET /api/sandbox/psp/payouts/:id` |
| `refund` | `POST /api/sandbox/psp/refunds` |
| `getBankAccount` | `GET /api/sandbox/bank/accounts/:ref` |
| `transfer` | `POST /api/sandbox/bank/transfer` |

The sandbox `/api/sandbox/bank/transfer` route was added for same-currency
provider transfers; it delegates to the idempotent `bank.transfer` primitive.

Requests carry:

- `x-api-key`
- `Idempotency-Key` (collection/payout transaction reference, transfer
  reference, or refund reference)

The adapter never marks a payment successful. It maps the provider's status
and lets the trade/payment state machine decide.

When CrossPay does not name a PSP, `SandboxPaymentProvider` asks
`GET /api/sandbox/psp/providers` and chooses the mobile-money provider for the
currency whose phone prefix matches the payer/recipient. Provider codes stay in
the provider's data, not in CrossPay source.

The sandbox `stk-push` response includes the full `request` view, so a
collection can be parsed in one round trip; the adapter still accepts the old
flat shape.

---

## 3. Collection, payout and refund behaviour

**Collection (B2.3).** `POST /trade/initiate` consumes the quote, re-checks the
daily limit, snapshots the encrypted recipient and creates one payment attempt.
The deterministic `CP-...` trade reference is the provider idempotency key.
A confirmed collection posts:

- deposit journal: `1000` partner trust cash / `2000` trade payable;
- fee journal: `1000` partner trust cash / `3000` fee revenue for the **net**
  platform fee (platform fee minus provider fee).

**Payout (B2.4).** `POST /trades/:id/disburse` moves an escrowed trade through
the generic matching states, creates one `payouts` row and calls
`createPayout`. A payout success posts three journals:

- FX source (send currency): debit `2000` / credit `5000`;
- FX destination (receive currency): debit `5000` / credit `2000`;
- payout (receive currency): debit `2000` / credit `1000`.

The two FX journals share `fx_group_id`; they are never summed together. A
payout rejection/failure refunds the payer and reverses both collection
journals. Bank rails return `503 PAYOUT_RAIL_NOT_CONFIGURED` until an approved
partner account contract exists.

**Refund (B2.4).** `POST /trades/:id/refund` asks the provider first, then
records `refunds` and reverses the deposit and fee journals. A late collection
after cancellation is booked and refunded automatically; the trade stays
`cancelled`.

**Callbacks.** `POST /api/v1/webhooks/payments/:provider` verifies
HMAC-SHA256 over `<timestamp>.<raw body>`, bounds the timestamp skew and stores
`(provider, provider_event_id)` uniquely. A replay returns
`{ received: true, replay: true }` without moving money.

---

## 3. Error mapping

| Provider result | Adapter result |
|---|---|
| 2xx valid body | typed collection/payout/refund/account/transfer |
| 4xx `{ error: { code, message } }` | `PaymentRejectedError(status, code, message)` |
| 4xx legacy `{ error: "CODE", message }` | `PaymentRejectedError` |
| 5xx / network / timeout | `PaymentUnavailableError('PAYMENT_PROVIDER_UNAVAILABLE')` |
| unreadable/invalid body | `PaymentUnavailableError('PAYMENT_PROVIDER_INVALID_RESPONSE')` |
| 404 on a read | `null` |

A rejected payment is not retried blindly. A transport/5xx failure can be
retried with the same idempotency key.

---

## 4. Configuration

```bash
PAYMENT_PROVIDER=disabled   # default; honest 503
PAYMENT_PROVIDER=sandbox    # reference provider
SANDBOX_PAYMENTS_URL=http://127.0.0.1:8080
SANDBOX_PAYMENTS_KEY=<sandbox API key>
PAYMENTS_TIMEOUT_MS=5000
COLLECTION_PUSH_TIMEOUT_SECONDS=120
COLLECTION_POLL_INTERVAL_SECONDS=5
PAYMENT_CALLBACK_URL=https://api.example.com/api/v1/webhooks/payments/sandbox
PAYMENT_WEBHOOK_SECRET=<shared HMAC secret>
PAYMENT_WEBHOOK_MAX_SKEW_SECONDS=300
```

An empty `PAYMENT_CALLBACK_URL` means no callback URL is sent. An empty
`PAYMENT_WEBHOOK_SECRET` keeps the callback endpoint at an honest
`503 WEBHOOKS_NOT_CONFIGURED`.

Production adapters must implement the same interface; do not reuse the
sandbox adapter for real money.

---

## 5. Verification

- `npm run typecheck` clean.
- `npm test` **84/84**, 17 suites.
- Adapter tests cover collection/payout idempotency, provider discovery by
  currency and phone prefix, refund, bank account read/transfer, rejection,
  outage and malformed responses.
- B2.4 tests cover payout success/FX journals, payout failure refund, provider
  rejection refund, user refund, late collection after cancel, webhook
  signature/replay protection and payout callbacks.
- Live smokes against the running sandbox:
  - `smoke:b2.3` — real quote, STK push, simulated PIN, claim, `escrowed`,
    balanced journals;
  - `smoke:b2.4` — TZS collection, sandbox FX liquidity, KES payout,
    `completed`, two linked FX journals;
  - `smoke:webhooks` — real signed collection and payout callbacks, both
    `signature_verified` and `processed`.

---

## 6. What remains

1. **Bank payout rails** — need an approved partner account contract and a
   configured source account per currency.
2. **Scheduled worker** — retry pending refunds/payouts, sweep match deadlines,
   expire stale quotes and reconcile provider statements.
3. **Real provider adapters and contract tests** — keep the sandbox as the
   reference.
4. **Liquidity providers and ops dashboard** — standing orders, corridor
   exposure monitoring and manual match controls (B4.4/B4.5).
5. **KYC/name-check adapters** — still disconnected.

The P2P matching engine (B4 v1) now calls this adapter's match-mode payout; see
`docs/B4_MATCHING_IMPLEMENTATION.md`.

The sandbox adapter is the reference implementation, not a production payment
provider.
