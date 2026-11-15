# P2P matching engine — plan

**Status**: proposed, not built
**Date**: 2026-11-15
**Owner**: CrossPay backend
**Related**: `docs/B2_IMPLEMENTATION.md`, `docs/B2_2_IMPLEMENTATION.md`,
`docs/api_contract.md`, `kachi-fintech-sandbox/docs/INSTITUTION_CUSTOMERS_PLAN.md`

---

## 0. Scope boundary

CrossPay owns the matching engine. The sandbox is a provider simulator only.

| Concern | CrossPay | Sandbox |
|---|---|---|
| Matching engine and queue | **Owns** | **Must not exist** |
| Customer quote, rate, spread, fees | **Owns** | Simulates provider fees/rates |
| Trade lifecycle and statuses | **Owns** | Unaware |
| Escrow and platform ledger | **Owns** | Provider ledger/settlement only |
| Limits, KYC status, sanctions | **Owns** | KYC provider simulates verification |
| Collections, payouts, refunds | Orchestrates | Simulates provider primitives |
| Provider rules | Follows | Enforces |
| Reconciliation and reporting | **Owns** | Provides statements |

CrossPay follows real provider rules. The sandbox must not relax a rule because
CrossPay's flow would look better. The production path is:

```
Flutter app → CrossPay API → provider adapters → sandbox providers
```

The sandbox `/api/v1` facade remains a reference/demo harness. It is not the
home of the matching engine, and it is not the production app backend.

---

## 1. What true P2P matching is

Two users' trades offset each other across a corridor:

- User A sends KES; A's recipient receives TZS.
- User B sends TZS; B's recipient receives KES.

No currency crosses the border:

- A's KES pays B's KES recipient.
- B's TZS pays A's TZS recipient.
- CrossPay keeps the spread and fees.
- Each leg is a local collection and a local payout through the providers.

This is **not** the current mobile-money `p2p` payout label. Providers never see
a match; they only receive independent collection and payout instructions.

---

## 2. Trade flow

Collect first, match second.

```
quote → initiate → collect payer → escrow → matching → matched → disbursing → completed
                                                     │
                                                     ├──► expired / refunded
                                                     └──► failed / refunded
```

Why collect first:

- A match promises two payouts.
- Matching unfunded trades exposes the funded side.
- Only escrowed trades enter the queue.

Status values already exist in `trades` and the Flutter model:
`pending_deposit`, `escrowed`, `matching`, `matched`, `disbursing`,
`completed`, `expired`, `refunded`, `failed`, `cancelled`.

---

## 3. Matching model — v1

**FIFO, full-fill, platform-quoted rate.**

Not a continuous exchange order book in v1.

Why:

- Users accept a fixed quote; they do not submit bid/ask prices.
- The platform owns the rate, spread and fee policy.
- The engine only needs an opposite funded trade that can honour both quotes.
- Full-fill protects the quoted receive amount.

### Match eligibility

A match is allowed only when:

1. Both trades are `escrowed`.
2. Same currency pair, opposite directions.
3. Both users are KYC-verified and within limits.
4. Both destination accounts/wallets exist and are active.
5. The destination provider currently accepts the payout.
6. Amounts are within the provider's per-transaction and daily limits.
7. The provider cutoff for that rail has not passed.
8. Neither trade is expired, cancelled or frozen.
9. One side's send amount can cover the other side's quoted payout after the
   spread.
10. Both quoted receive amounts can be paid in full.

If any condition fails, do not match. Queue, fall back to the bank route, or
refund.

### Order of priority

1. Oldest eligible funded trade.
2. Trade id for determinism.
3. No random matching.

### Concurrency

- Lock both trades `FOR UPDATE` in one transaction.
- Re-check status and amounts inside the transaction.
- Insert `p2p_matches` with status `locked`.
- Update both trades to `matched`.
- Append timeline events.
- Commit.
- The unique `(buy_trade_id, sell_trade_id)` pair prevents duplicate matches.

---

## 4. Rate and spread

CrossPay decides the customer-facing quote and spread. It does not decide the
underlying market rate.

| Rate | Owner |
|---|---|
| Market/reference rate | Market/pricing source |
| Provider rate and quote validity | PSP/bank/liquidity partner |
| Customer quote and spread | **CrossPay**, within provider constraints |
| Match clearing rate | **CrossPay**, must cover both quotes |
| Partner settlement rate | Contractual |

The pricing service must:

1. source a real rate,
2. apply the approved spread,
3. respect provider quote validity and liquidity,
4. lock the customer quote for its window,
5. hedge or match the exposure.

A match must not quote more than the two local legs can honour. If it cannot,
the trade waits, falls back or refunds.

### Worked example

- A sends KES 1,000 (`100,000` minor), quoted TZS 17,400.
- B sends TZS 17,500, quoted KES 1,000.
- A's KES funds B's KES payout.
- B's TZS funds A's TZS payout of 17,400.
- CrossPay retains the TZS 100 residual plus fees.

No FX transaction occurs for the matched pair. Each trade posts its own
single-currency collection and payout.

---

## 5. Data model

Existing:

- `trades` with `matching` and `matched` statuses.
- `p2p_matches`:
  - `buy_trade_id`, `sell_trade_id`
  - `buy_amount_minor`, `sell_amount_minor`
  - `buy_currency`, `sell_currency`
  - `status`: `proposed`, `locked`, `released`, `cancelled`, `failed`
  - `matched_at`, `released_at`
  - unique pair

Add:

1. `match_rate numeric(20,10)` on `p2p_matches` for audit.
2. `p2p_match_events`:
   `id`, `match_id`, `event`, `note_code`, `actor`, `created_at`.
3. `match_deadline_at` on `trades` (or derive from quote/payment expiry).
4. `matched_minor`/remaining fill tracking if partial fills are enabled later.
5. `p2p_match_allocations` for partial fills later.
6. Corridor exposure/liquidity settings.

No separate order-book table in v1. The queue is derived from escrowed trades
in the corridor, ordered by escrow time.

---

## 6. Algorithm

For each corridor pair:

```
on trade escrowed:
  mark trade matching
  enqueue

sweep(corridor):
  candidates = escrowed, unexpired, eligible trades, oldest first
  for each candidate A:
    for each opposite candidate B, oldest first:
      if can_cover(A, B) and can_cover(B, A):
        begin transaction
          lock A and B
          re-check status, amounts, provider eligibility
          insert p2p_match(status=locked, match_rate)
          update A and B to matched
          append events
        commit
        schedule payout saga
        break
```

`can_cover` checks:

- B's send amount >= A's quoted payout (in B's currency), and
- A's send amount >= B's quoted payout (in A's currency),
- provider limits, cutoffs, account status and currency rules.

The worker runs after commit. It does not hold a database transaction open
while calling providers.

---

## 7. Payout saga

Two providers cannot commit atomically. Use a saga.

1. Reserve both payout legs.
2. Send both provider payout instructions.
3. Record provider references and pending states.
4. If both succeed:
   - mark match `released`,
   - mark trades `completed`,
   - post payout ledger entries.
5. If one fails:
   - do not send the other if it has not started,
   - if the other already paid, compensate from liquidity or reverse/refund,
   - mark match `failed`,
   - mark affected trades `refunded`/`failed`,
   - append events and ledger reversals.
6. Retries are idempotent by provider reference.
7. A late provider reversal after completion is handled as a post-completion
   adjustment, not by editing history.

“Instruction accepted” is not “recipient paid.” The trade completes only when
the provider confirms the payout.

---

## 8. Provider rules that constrain matching

Before a match, CrossPay must check the destination provider:

- per-transaction and daily limits,
- currency and account format,
- account/wallet status,
- KYC tier and name-match requirements,
- payout cutoffs and business days,
- provider availability/health,
- settlement window,
- reversal/return policy.

If either leg cannot execute under those rules, the match is invalid. CrossPay
must not bypass a provider limit, cutoff or name check to make a match happen.

---

## 9. Ledger and settlement

Each trade posts its own collection when escrowed. The match does not convert
currency.

| Leg | Debit | Credit |
|---|---|---|
| A's TZS payout | TZS trade payable/escrow | TZS PSP payable / recipient wallet |
| B's KES payout | KES trade payable/escrow | KES PSP payable / recipient wallet |
| Spread | spread/FX revenue | corresponding payable |

Every journal is single-currency and balanced. There is no cross-currency
journal between A and B.

If CrossPay uses its own liquidity to fill a gap, that is a separate FX
transaction with two currency legs linked by `fx_group_id`.

The exact escrow, spread and settlement accounts need Finance/Legal approval.

---

## 10. Failure and refund

| Case | Behaviour |
|---|---|
| No match by deadline | Expire; fall back to bank route if opted in, otherwise refund |
| Cancel while matching | Remove from queue, refund, `cancelled` |
| One leg payout fails | Compensate/refund; match `failed`; trades `refunded`/`failed` |
| Wallet/account missing or frozen | Do not match; fail with provider code |
| Provider outage | Keep match `locked`; retry idempotently; do not pay the other leg blindly |
| Provider reversal after completion | Post-completion adjustment; ledger reversal |
| Quote cannot be honoured | Do not match; queue/fallback/refund |

No ledger row is edited or deleted. Corrections are reversals.

---

## 11. Liquidity

A matching engine with no opposite flow does nothing.

Sources:

1. Organic users sending the opposite direction.
2. Professional liquidity providers with pre-funded accounts in both
   currencies, posting standing orders.
3. CrossPay treasury / bank route as fallback.

Launch rules:

- Show `p2p` only when queue depth or LP liquidity is sufficient.
- Show expected wait from the queue.
- Offer the bank route as the immediate alternative.
- Expire unmatched trades and refund or fall back.
- Enforce corridor exposure caps.

`GET /market/depth` already exists in the contract for queue depth and
estimated settlement time.

---

## 12. App and ops

### App
- Route card shows matching availability, expected wait and matching density.
- Tracker shows `Matching your transfer` → `Matched` → `Disbursing` →
  `Completed`.
- Cancel is allowed while matching.
- No counterparty identity is ever revealed.

### CrossPay ops/dashboard
- P2P queue per corridor: both sides, amount, age, KYC tier, status.
- Active matches and both legs.
- Released, failed, expired and cancelled history.
- Manual match and auto-match controls.
- Corridor exposure, liquidity and match deadlines.
- Provider eligibility/health at a glance.

### Sandbox
- No matching panel, no match endpoints, no queue.
- It shows provider collections, payouts, wallets and statements only.

---

## 13. Build order

1. **Sandbox provider realism**
   - PSP wallets, bank customers, KYC identities.
   - Provider rules, limits, cutoffs, fees, callbacks.
   - No matching.

2. **CrossPay provider adapters**
   - PSP collection/payout/refund/status.
   - Bank transfer/status/returns.
   - KYC/name-check.
   - Contract tests against the sandbox.

3. **CrossPay B2.3/B2.4**
   - Initiate, collect, escrow, payout, refund, webhooks.
   - Trade lifecycle and ledger.
   - Honest provider failures.

4. **Matching engine**
   - Queue, eligibility, FIFO full-fill, match records, locks.
   - Payout saga with compensation.
   - Exposure and liquidity controls.

5. **App integration**
   - Point the app at CrossPay API.
   - Route availability, matching tracker, cancel/fallback.

6. **Liquidity providers and partial fills**
   - Standing orders, LP limits, partial fills, platform top-up.

The matching engine comes **after** payments work, because a match is
meaningless without two executable payout legs.

---

## 14. Testing

- Two funded opposite trades match; both payouts complete.
- Status timeline: escrowed → matching → matched → disbursing → completed.
- Ledger balances for both currencies.
- No match by deadline → expiry and refund.
- Cancel while matching → refund.
- One-leg payout failure → compensation, match failed, ledger reversal.
- Missing/frozen wallet or account → no match.
- Provider limit/cutoff/health failure → no match or fallback.
- Concurrency: two workers cannot double-match.
- Rounding: quoted amounts are paid exactly; spread is retained.
- Exposure caps and corridor limits.
- Provider callbacks and retries are idempotent.
- Live Flutter flow with two users in opposite directions.
- All existing CrossPay API tests and sandbox contract tests remain green.

---

## 15. Open decisions

1. Full-fill only in v1? **Recommended yes.**
2. Collect-then-match? **Recommended yes.**
3. FIFO at the platform quoted rate, not a user order book? **Recommended
   yes.**
4. Fallback to bank or refund on timeout? **Recommended user choice at quote,
   default refund.**
5. Launch liquidity: organic, LP, or treasury? **Product/Finance.**
6. Match deadline and corridor exposure caps? **Product/Finance/Risk.**
7. Partial fills later? **Yes, after full-fill is proven.**
8. Spread policy and who bears residual? **Product/Finance.**

---

## 16. Acceptance criteria

1. Two users in opposite corridors get quotes.
2. Both are collected and escrowed.
3. The engine matches them.
4. Both recipients are paid locally in their own currency.
5. Both quoted receive amounts are honoured exactly.
6. CrossPay retains the spread and fees.
7. No currency crosses the border.
8. A one-sided queue expires and refunds or falls back.
9. A one-leg payout failure is compensated without double-paying.
10. The dashboard shows the queue, match and both legs.
11. No matching code exists in the sandbox.
12. All tests pass from a restored snapshot.

---

## 17. Non-goals

- No matching engine in the sandbox.
- No provider rule bypass to make a match happen.
- No guarantee of an instant match.
- No cross-border currency movement in a matched pair.
- No counterparty identity disclosure to users.
- No full exchange order book in v1.
- No partial fills in v1.
