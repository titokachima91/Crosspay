# B4 P2P matching engine — v1 implementation

**Status**: built and verified 2026-11-16.
**Code**: `server/src/matching.ts`, `server/src/http/routes/matching.ts`,
`server/src/payments.ts` (match-mode payout)
**Schema**: `server/db/migrations/0008_p2p_matching.sql`
**Tests**: `server/test/matching.test.ts`
**Live smoke**: `npm run smoke:b4`
**Plan**: `docs/P2P_MATCHING_PLAN.md`

---

## 1. Scope

This is the CrossPay matching engine, not a sandbox feature. Two funded users in
opposite directions match; each user's collected principal pays the other
user's payout in the same currency.

- A sends TZS, receives KES.
- B sends KES, receives TZS.
- A's KES collection pays B's KES payout.
- B's TZS collection pays A's TZS payout.
- No FX transaction occurs for a matched pair.

Only **mobile-money (`route = p2p`)**, **escrowed** trades enter the queue.
Bank payouts are not connected, so they are rejected with
`503 PAYOUT_RAIL_NOT_CONFIGURED`.

---

## 2. Kill switches and policy

Two independent switches:

1. `P2P_ENABLED=true` in the environment. Default `false`.
2. An enabled row in `p2p_corridors` for the exact direction with a non-null
   `exposure_cap_minor`.

No corridor is seeded. A production or sandbox operator must insert an approved
row. This keeps corridor policy out of source code.

```sql
INSERT INTO p2p_corridors
  (send_currency, receive_currency, enabled, exposure_cap_minor,
   match_deadline_seconds, spread_bps)
VALUES ('TZS', 'KES', true, 1000000000, 600, 50),
       ('KES', 'TZS', true, 1000000000, 600, 50);
```

`spread_bps` is provisional policy metadata; the customer quote owns the actual
rate. Production matching still requires Finance/Risk approval of the corridor,
spread and exposure.

---

## 3. Queue and match creation

`tryMatchTrade(ctx, { tradeId, userId? })`:

1. Requires `P2P_ENABLED`.
2. Locks the trade; requires `escrowed` or `matching`.
3. Loads and locks the corridor; requires `enabled` and an exposure cap.
4. Computes the deadline (`match_deadline_at` or `created_at + corridor
   seconds`). A passed deadline moves the trade to `expired`; the caller then
   refunds it.
5. Moves `escrowed → matching` and sets `match_deadline_at`.
6. Rejects the corridor when its open send exposure is already above cap.
7. Selects candidates in `escrowed`/`matching`, opposite direction, different
   user, oldest first, `FOR UPDATE SKIP LOCKED`:
   - coverage: each send amount >= the other's quoted receive amount;
   - candidate corridor enabled, deadline not passed;
   - candidate currency exposure within cap.
8. Inserts one `p2p_matches` row (`locked`, `match_rate`, matched_at).
9. Moves both trades through `matching → matched` (candidate may start
   `escrowed`).
10. Appends `p2p_match_events`.

The endpoint `POST /api/v1/trades/:id/match` runs one attempt for one trade.
The claim route and signed collection webhook call the same service after a
collection is confirmed, so a newly funded trade can match immediately.

A queued trade is not lost: when the opposite trade arrives and its claim or
webhook runs, the candidate query finds the queued `matching` trade.

---

## 4. Match ledger

Each leg posts a `p2p_settlement` journal in the receive currency when its
payout is about to succeed:

| Line | Account | Amount |
|---|---|---|
| Debit | `2000` trade payable | counterpart's send principal |
| Credit | `2000` trade payable | this trade's receive amount |
| Credit | `3100` spread revenue | counterpart principal − receive amount |

Then the normal `payout_sent` journal clears the receive payable:

| Line | Account | Amount |
|---|---|---|
| Debit | `2000` trade payable | receive amount |
| Credit | `1000` partner trust cash | receive amount (plus provider fee if any) |

Both journals are single-currency and balanced. The matched pair's two
settlement journals are linked by `fx_group_id = match id`, but their minor
units are never summed across currencies.

The customer fee journals were already posted at collection; the match does not
re-post them.

---

## 5. Two-leg payout saga

`disburseMatch(ctx, { matchId, userId? })` pays the legs in creation order.

1. Lock the match and both trades.
2. If the match is already `released`, return.
3. Start/resume the first leg in match mode.
4. If the first leg fails before paying:
   - no settlement journal was posted;
   - refund both customers;
   - mark the match `failed`.
5. If the first leg is pending/submitted, keep the match `locked`; retry later.
6. If the first leg paid, start/resume the second leg.
7. If the second leg is pending, keep the match `locked`.
8. If both paid, mark the match `released`.
9. If the second leg fails after the first paid:
   - refund the second customer normally;
   - the first payout used part of the second customer's collected principal,
     so cash would go negative by the first payout amount;
   - post a `p2p_compensation` journal in the second trade's send currency:
     debit `1000` partner trust cash / credit `7000` CrossPay treasury funding;
   - mark the match `failed`;
   - the first trade stays `completed` because its recipient was paid.

The match endpoint is idempotent and safe to retry after an outage. A pending
provider payout is resumed by re-reading it with the stored provider reference,
not by creating a second payout.

---

## 6. Deadline, refund and worker

- A `matching`/`escrowed` trade past `match_deadline_at` moves to `expired` and
  is refunded by the same service call.
- A trade cancelled before matching is refunded through the normal refund path.
- `npm run worker` runs the reconciliation pass continuously
  (`WORKER_INTERVAL_SECONDS`, default 30); `WORKER_ONCE=true` runs one pass for
  cron. Each pass:
  - expires stale quotes;
  - expires and refunds past-deadline match trades;
  - resumes locked matches (re-reads pending provider payouts);
  - resumes direct-liquidity payouts;
  - retries pending/submitted refunds.
- Every worker action is idempotent by posting key, provider reference or
  refund row.

---

## 7. API

These are server/ops triggers; the Flutter app does not need to call them.

| Method | Path | Auth | Behaviour |
|---|---|---|---|
| POST | `/api/v1/trades/:id/match` | user | one FIFO attempt; `200` matched/expired, `202` queued |
| POST | `/api/v1/matches/:id/disburse` | one leg's user | pay/resume both legs |

Responses never reveal counterparty identity. They expose the match id, status,
currencies, amounts and the caller's leg state.

`503 MATCHING_DISABLED` when `P2P_ENABLED=false`.
`409 CORRIDOR_NOT_MATCHABLE` when no enabled corridor exists.
`409 CORRIDOR_EXPOSURE_EXCEEDED` when the cap is reached.

---

## 8. Verification

`server/test/matching.test.ts` covers:

- two funded opposite trades match FIFO and both payouts release;
- no opposite trade leaves a funded trade `matching` with a deadline;
- past deadline expires and refunds;
- first-leg payout failure refunds both legs with no settlement journal;
- second-leg failure after the first paid books compensation and leaves the
  first trade completed;
- all journals balance, including the spread and compensation entries.

`server/test/worker.test.ts` covers:

- stale quote expiry;
- direct payout resume from the provider status;
- deadline expiry and refund;
- pending refund retry after a provider outage;
- locked match resume to released.

Live `smoke:b4` against the running sandbox:

- real TZS and KES collections;
- automatic match on the second claim;
- two simulated provider payouts;
- match `released`, both trades `completed`;
- journals: deposit/fee TZS, deposit/fee KES, `p2p_settlement` KES,
  `payout_sent` KES, `payout_sent` TZS, `p2p_settlement` TZS;
- every journal transaction balances.

The sandbox publishes a reciprocal mid-rate, so the live smoke applies a
test-only 1,000-minor-unit spread to each quote to create a genuine
cross-coverage gap. A real platform spread policy is not built yet; this is
called out rather than hidden.

Node suite after B4, market depth, analytics, export and the worker:
**88/88**, 18 suites, typecheck clean.

---

## 9. Deliberate limits

- Full-fill only; no partial fills or standing liquidity orders.
- No ops dashboard (queue depth, match list, manual match controls). The
  `GET /market/depth` read model is built from real funded queues.
- No provider cutoff/business-hours engine beyond the match deadline.
- Bank payout legs are not connected.
- `7000` treasury funding is a liability, not an automatic write-off; Finance
  decides when compensation becomes an expense.
- Production matching remains disabled until Risk/Finance approve the corridor,
  spread and exposure values.
- The worker is a process, not a distributed queue; run one instance or rely on
  the idempotent row locks when running several.
