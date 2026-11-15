# CrossPay payment adapters

**Status**: provider boundary and sandbox adapter built 2026-11-15. B2.3
initiation and B2.4 payouts/refunds are the next step.
**Code**: `server/src/providers/payments.ts`,
`server/test/payment-provider.test.ts`
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
```

Production adapters must implement the same interface; do not reuse the
sandbox adapter for real money.

---

## 5. Verification

- `npm run typecheck` clean.
- `npm test` **53/53**, 12 suites.
- New adapter tests cover:
  - collection create/read with key and idempotency;
  - payout create/read;
  - refund;
  - bank account read and same-currency transfer;
  - 422 rejection, 503 outage, malformed response;
  - disabled default.
- Live smoke against the running sandbox:
  - `CRDB-DEMO-001` balance 2,000,000 TZS;
  - transfer 1,000 TZS to a new CRDB customer;
  - source 1,999,000, destination 1,000;
  - state `COMPLETED`.

---

## 6. What remains

1. **B2.3 `/trade/initiate`** — consume the quote, snapshot the recipient,
   create the trade and payment attempt, call `createCollection`, return
   collection instructions.
2. **B2.4 payouts/refunds** — call `createPayout`, poll/webhook, complete the
   trade, refund on failure.
3. Payment attempt state machine and ledger postings.
4. Provider callback signature verification and replay protection.
5. Real provider adapters and contract tests.
6. Matching engine after payments are stable.

The sandbox adapter is the reference implementation, not a production payment
provider.
