# Revenue, operating accounts and bookkeeping

**Status**: rule recorded 2026-11-16. The sandbox has a testing-only revenue
stand-in; the CrossPay admin bookkeeping section is not built yet.
**Applies to**: CrossPay backend, CrossPay admin, `kachi-fintech-sandbox`

---

## 1. The rule

Every penny is recorded where it has to be recorded.

1. CrossPay does not hold customer cash and has no customer wallet.
2. Customer funds stay in the customer's account at the PSP or bank.
3. CrossPay's own money sits in **normal operating accounts**:
   - its bank operating account (`CPA-OPERATING-<bank>-<ccy>`);
   - its PSP operating/settlement account where a PSP pays fees over.
4. CrossPay's **admin bookkeeping section** is the home of its income. It
   records the collective fee/spread income against those real accounts, with
   enough detail to trace each amount back to a trade or settlement.
5. The sandbox is a provider simulator. It records what the provider side sees:
   customer wallets, PSP clearing/payable, partner trust/settlement/clearing,
   and the fee the PSP owes CrossPay (`CROSSPAY-PAYABLE-<ccy>`).
6. The sandbox's `CROSSPAY` mirror book is **testing-only**. It exists so tests
   can prove the revenue path end-to-end until the admin bookkeeping exists. It
   is labelled `testingOnly` and must be removed when the admin section is
   built.

The sandbox is not CrossPay's home, and the admin must not depend on the
sandbox ledger.

---

## 2. Where each amount lives

| Amount | Provider side (PSP/bank/sandbox) | CrossPay side |
|---|---|---|
| Customer principal | Customer wallet/account | Never held |
| Collected float | Partner trust/escrow or PSP clearing | Not a customer balance |
| PSP fee | Provider fee revenue | Cost of sale |
| CrossPay fee | `CROSSPAY-PAYABLE-<ccy>` (PSP owes CrossPay) | Fee revenue in the charged currency |
| FX spread | Not a provider item | Spread/FX revenue in the charged currency |
| Settlement to CrossPay | Debit `CROSSPAY-PAYABLE`, credit `CPA-OPERATING-...` | Receipt into the bank/PSP operating account |
| Refund | Provider refund; provider fee journal reversed | Revenue and receivable reversed |

A fee is charged in the currency actually charged. KES minor units are never
compared with TZS minor units; a conversion is two linked single-currency
journals in CrossPay's ledger, never one mixed journal. `5000 FX clearing` is
the technical bridge between those two journals and is never summed across
currencies. A provider fee charged on a payout is booked to `6000 Provider
fees` in the payout currency, not netted out of an unrelated currency.

| `2050` | Liquidity provider payable | LP prefund and settlement position |
| `3100` | Spread revenue | P2P match residual: counterpart principal minus the quoted payout |
| `6000` | Provider fees | Provider payout fees in the payout currency |
| `6100` | Compensation expense | Approved write-off of a treasury advance |
| `7000` | CrossPay treasury funding | Liability created when treasury covers a failed matched leg |

A matched P2P pair posts one `p2p_settlement` journal per currency: it releases
the counterpart's principal, creates the other customer's payout payable and
books the residual to `3100` spread revenue. No FX journal exists for a matched
pair. An LP prefund is booked when the standing order is created (`1000` cash /
`2050` LP payable) and returned on cancellation; an LP fill consumes `2050` in
the provide currency and records the send-currency obligation to the LP. When a
second leg fails after the first paid, `7000` records the treasury advance that
keeps partner trust cash from going negative; Finance can later write it off to
`6100` after approval.

---

## 3. Admin bookkeeping shape (target)

The admin bookkeeping section is a real ledger, not a dashboard counter.

Suggested revenue accounts:

| Code | Account | Meaning |
|---|---|---|
| `4100` | Transfer fee revenue | Platform fee per trade, by send currency |
| `4200` | FX spread revenue | Difference between the customer rate and the cover rate |
| `4300` | Payout/rail fee revenue | Any separately charged bank/rail fee |
| `4900` | Other income | Approved adjustments only |

Each entry should carry:

- trade reference and trade id;
- corridor (send → receive), rail and provider;
- currency and integer minor units;
- amount charged, PSP cost and net amount;
- settlement reference (bank/PSP statement line);
- reversal reference when refunded.

Controls:

- revenue is recognised only when collected;
- a refund reverses the revenue in the same currency;
- a settlement moves cash between CrossPay accounts, not revenue;
- daily reconciliation compares provider statements, bank/PSP operating
  accounts and the admin ledger;
- any difference is an explicit suspense item, never a silent adjustment.

---

## 4. Sandbox stand-in (today)

- `GET /api/sandbox/revenue/summary` returns `testingOnly: true` and the note
  that the sandbox is not CrossPay's home.
- `POST /api/sandbox/revenue/settle` posts two linked journals:
  - provider book: debit `CROSSPAY-PAYABLE`, credit the partner operating bank
    account (`CPA-OPERATING-...`);
  - testing mirror: debit operating cash, credit the provider receivable.
- A refunded trade reverses the provider fee journal and the testing mirror's
  fee revenue, so the two books stay in step.
- The dashboard panel is titled **CrossPay Revenue (testing stand-in)**.

**Removal condition**: delete the sandbox `CROSSPAY` accounts, revenue service,
route, panel and tests once the CrossPay admin bookkeeping section can record
the same amounts against CrossPay's real operating accounts.
