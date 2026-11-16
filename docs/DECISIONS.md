# CrossPay decisions (settled)

Product
- For everyone: personal and business accounts. Verification decides what a
  person can do; tiers and limits come only from the server.
- No wallet, no balance. "Receive" = payout to the recipient's mobile money or
  bank account. A "request money" link is a possible post-launch feature.
- Fees are added on top (sender pays amount + fee; recipient gets the full
  converted amount). The server calculates; the app displays.
- Home shows "Available today" (remaining daily limit), not a float balance.

Technology
- Backend: Node.js + TypeScript API, managed PostgreSQL (Supabase hosting is
  fine). Ledger rules run in database transactions. No Redis at first: quotes
  are stored with an expiry time. Own OTP/token endpoints (not Supabase Auth).
- Android minimum: Android 6 (API 23).
- Stay signed in after restart: yes, behind PIN/biometric, with refresh
  tokens (built in F5.3; contract already defined).
- Language choice is remembered (built in F5.3).
- Android SMS auto-read when an SMS partner exists.
- Simulated data lives ONLY in preview/. The real app (lib/) never imports it.
- Identity data (ID/TIN) is never stored, kept in state or logged on the device.
- CrossPay does not hold customer cash. Its money sits in normal bank/PSP
  operating accounts, and the CrossPay admin bookkeeping section records every
  penny of fee/spread income against them. The sandbox `CROSSPAY` revenue book
  is a testing-only stand-in and must be removed when that admin section exists:
  see `docs/REVENUE_AND_BOOKKEEPING.md`.

Only the founder can do (open items)
- Hire a local financial-regulation lawyer BEFORE any public launch: licensing
  for consumer transfers, the "non-custodial" claim, KYC privacy notice
  wording, privacy policy, data-protection registration in each country.
- Run the pilot through a licensed bank / payment partner.
- Choose the final name (BantuPay / CrossPay / AfrEX); check domain and trademark.
- Open partner conversations: SMS provider, mobile money aggregators, bank.
- Supply a logo file and the privacy policy text.

Home screen (F3.1)
- Converter figures come from the server (GET /trade/estimate, debounced).
- Currency decimals come from the server; amounts are whole numbers in the
  smallest unit (displayed value x 10^decimals).
- Bell icon left out until notifications exist; "Saved recipients" row shows
  people only; "+ Add new" / "View all" arrive with F5.2.
- Over-limit and not-verified messages are display checks; the server enforces.

Route selection (F3.2)
- Each card shows "You pay" (amount + fee) and "Recipient gets" (full
  converted amount); the old single "total payout" line is gone.
- A safeguard line (escrow, treasury sweep) appears only when the server sends
  a safeguardCode AND the app has approved wording for it.
- Fee lines come from the server. "Fastest" replaces the "Instant" badge
  because speeds are data, not a promise.
- A new quote is requested every time the screen opens. When the lock ends,
  the screen offers "Get a new rate" and never re-prices silently.

Recipient details (F3.3)
- The name check returns match / mismatch only, never the registered name.
- Authorize needs: lock still running, account found, name matches. If the
  name cannot be checked automatically, paying is allowed with a visible
  warning (partners and the lawyer must confirm they accept this).
- One idempotency key per authorization attempt (same quote + same details =
  same key). The rate-lock countdown is also shown on this screen.
- Payout rails are chips (names come from the server); a saved recipient
  tapped on Home prefills the form, and the check runs again.

Payment prompt (F3.4)
- Only the server's trade status decides that money arrived. "I have completed
  manual payment" just asks the server to re-check.
- Timings (when to open the manual fallback, how often to check) come from
  the server. Checking is by polling for now; live push may replace it later.
- Cancel asks for confirmation (a payment already approved on the phone may
  still go through) and calls the server; if the server refuses, the app keeps
  watching. Leaving the screen while a payment is in progress is the same as
  cancelling: it always asks first.
- The ONE idempotency key per authorization attempt is used for the initiate
  request and its retries, so a reopened screen can never collect twice.
- Wording is plain ("payment request sent to your phone") instead of "STK push".

Backend collections, payouts and refunds (B2.3/B2.4)
- The trade reference is deterministic and doubles as the provider idempotency
  key. A database rollback after a provider call must never create a second
  charge.
- Collection posting keeps principal and fee separate: partner trust cash /
  trade payable, then partner trust cash / fee revenue for the net fee after
  the provider fee. The gross amount the payer tapped is never revenue.
- Payout success is three journals: FX source in the send currency, FX
  destination in the receive currency, then the payout. `fx_group_id` links the
  FX pair. Minor units are never summed across currencies.
- A payout rejection/failure refunds the payer and reverses both collection
  journals before the error leaves the server.
- A late collection after cancellation is booked and refunded; the trade stays
  cancelled. Money is never invisible.
- `refund` after a completed payout is refused (`PAYOUT_ALREADY_SENT`); a
  clawback is a dispute flow.
- Provider callbacks authenticate with HMAC over the raw body and a bounded
  timestamp. `(provider, provider_event_id)` is unique; a replay moves no money.
- Bank payout rails stay an honest `503 PAYOUT_RAIL_NOT_CONFIGURED` until an
  approved partner account contract exists. Mobile-money payout is live.
- The sandbox is authoritative for PSP codes by currency and phone prefix;
  CrossPay does not hardcode provider routing.
- The sandbox needed a separate KES pay-in to fund a KES payout. That is test
  liquidity in the simulator, not an invented production balance.

P2P matching (B4 v1)
- Collect first, match second. Only funded escrowed trades enter the queue.
- FIFO full-fill at the platform quote. No order book, no partial fills.
- Matching is off unless `P2P_ENABLED=true` AND an enabled corridor row with an
  exposure cap exists. No policy lives in code.
- A match is single-currency per leg: the counterpart's principal pays the
  payout, with the residual booked to spread revenue. No FX journal.
- A first-leg failure refunds both customers. A second-leg failure after the
  first paid refunds the second and books a treasury advance; the first stays
  completed because its recipient was paid.
- Match deadlines expire and refund. A scheduler is still required to sweep
  them and pending legs.
- The live smoke applies a test-only spread because the sandbox has a
  reciprocal mid-rate. A real platform spread policy is not built yet.
- Counterparty identity is never returned by the API.

Reconciliation worker
- A single `runWorkerPass` is shared by the HTTP process (not automatically) and
  `npm run worker`; the worker is a separate process so API latency is not tied
  to provider retries.
- Every pass is idempotent and safe to overlap with the API or another worker.
- The worker expires quotes and match deadlines, resumes locked matches and
  direct payouts, and retries pending refunds. It never invents a provider
  status; it re-reads the provider's record.
- `WORKER_ONCE=true` supports cron; the default interval is 30 seconds.

Market depth, analytics and export
- Market depth is a read model over funded trades, not an invented liquidity
  score. A corridor appears only when an operator enabled it and supplied an
  `estimated_settle_seconds`; otherwise it is omitted.
- Analytics counts completed trades only, in the account's reporting currency.
  The totals cover the highest-volume receive currency; the API never adds
  minor units across currencies.
- CSV export is built by the server and downloaded through a five-minute
  single-purpose token. The link is public only because the token is the
  authentication. No public URL means an honest `503`, never a broken link.
- Invoice/share stay unavailable until a QR/share service exists.

Liquidity providers and Phase A admin
- LPs are allowlisted and pre-funded; there is no public onboarding. An order's
  remaining capacity is the prefunded provide-currency balance not yet consumed.
- Creating an order requires an operator prefund reference and books
  `1000` cash / `2050` LP payable. Cancelling an unused order returns the
  remaining prefund. A locked match blocks cancellation.
- Matching tries organic opposite trades first, then the cheapest eligible LP
  order. LP payouts post one send and one receive settlement journal, never a
  mixed-currency journal.
- A failed LP payout refunds the customer and returns the reserved capacity
  exactly once (`liquidity_released_at`).
- The Phase A admin is an `ADMIN_API_KEY` break-glass surface, not the final
  admin. It is read-heavy plus corridor/LP controls and manual match/disburse.
- Every Phase A admin write is append-only audited as `env-admin`. Named admin
  users, TOTP, RBAC, approvals and bookkeeping are planned in
  `docs/ADMIN_PANEL_PLAN.md`.
- The sandbox testing-only revenue mirror remains until the admin bookkeeping
  and settlement/reconciliation phases pass.
