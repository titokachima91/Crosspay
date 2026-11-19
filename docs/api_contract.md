# CrossPay API contract

**Status**: Reconciled for the B1 database foundation — 2026-11-14
**Authority**: This document is the contract of record for the Flutter client and
the Node.js API. `docs/B1_DATABASE_PLAN.md` defines the storage that serves it.

Conventions
- Base path: /api/v1
- Money: whole integers in minor units (for example, kobo or cents), scaled by
  the currency's `decimals` from /config. Rates are decimal numbers.
- IDs are opaque server-issued strings. Clients never parse them.
- Times: ISO-8601 UTC. The server clock is authoritative for expiry and limits.
- Writes carry X-Idempotency-Key; the server must honor it.
- Errors: { "error": { "code": "SOME_CODE", "message": "for logs" } }
- Endpoints marked "no login" must work without a token.
- Repeating a write with the same key and the same body returns the original
  result, marked with `Idempotency-Replay: true`.
- Reusing the key with a different body returns
  `409 IDEMPOTENCY_KEY_REUSED`.
- A duplicate that arrives while the first request is still running normally
  waits for that transaction and then replays its committed result. If the
  server cannot wait, or observes a committed in-progress row, it returns
  `409 IDEMPOTENCY_IN_PROGRESS` with a `Retry-After` header. It must never
  execute the operation a second time.

## GET /api/v1/config   (no login)
{
  "currencies":  [ { "code": "<ISO code>", "name": "<name>", "countryCode": "<2 letters>",
                     "decimals": <digits shown after the decimal point, e.g. 0 or 2> } ],
  "hubs":        [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>" } ],
  "payoutRails": [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>",
                     "kind": "mobile_money | bank" } ],
  "countries":   [ { "code": "<2 letters>", "name": "<name>", "dialCode": "<digits, e.g. 255>",
                     "nationalNumberLength": <digits after the dial code, no leading zero> } ],
  "carriers":    [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>",
                     "prefixPattern": "<regex matched from the START of the national number>" } ],
  "support":     { "email": "<address>", "phone": "<number>", "whatsapp": "<number>",
                   "hours": "<free text>" },   (optional, every field optional)
  "service":     { "quotesPaused": <bool>, "tradesPaused": <bool>,
                   "message": "<short operator message>" },   (optional)
  "banners":     [ { "id": "<uuid>", "messageEn": "<text>", "messageSw": "<text>",
                     "severity": "info | warning | critical",
                     "startsAt": "<ISO-8601 UTC>", "endsAt": "<ISO-8601 UTC>" } ]
                                                   (optional, active windows only)
}
All five lists are required (they may be empty). The first country listed is
the default on the phone screen. Carrier matching is a suggestion only.
`support` is optional. Omit it, or omit individual fields, until a real support
desk exists; the app then says support contact options are not available yet
instead of inventing an address or number. The app only offers copy actions
today; in-app message submission is not connected.
`service` is optional and appears only while an emergency pause or operator
message is active. The Flutter app renders it as a maintenance banner above the
signed-in tabs. The pause itself is enforced by the quote and trade endpoints
with `503 SERVICE_PAUSED`.
`banners` is optional and contains only published banners whose window includes
the server's current time (`startsAt` inclusive, `endsAt` exclusive). Both
language texts and the window are approved and stored in the admin portal; the
app shows `messageSw` when the selected language is Swahili and `messageEn`
otherwise, and re-checks the window before rendering. The server never derives
a banner from a template, and an expired banner is not extended automatically.

## GET /api/v1/rates   (no login)
{
  "rates": [
    {
      "from": "<currency code>",
      "to": "<currency code>",
      "rate": <number>,
      "change24hPercent": <number, optional>,
      "status": { "code": "<status code>", "level": "healthy | limited | down" }  (optional)
    }
  ],
  "queueHealth": { "p2pDensityPercent": <0-100>, "bankSweepPercent": <0-100> }  (optional)
}
- "rate" = how many "from" units equal ONE "to" unit.
- Currency codes must exist in /config; other rates are ignored by the app.
- Order matters: the splash shows each pair once, in the first direction listed.
- Known status codes the app translates: balanced_p2p, high_liquidity,
  active_clearing. Unknown codes fall back to the level.
- Until the server operator connects a pricing provider (the sandbox reference
  provider is one), the endpoint returns `503 PRICING_NOT_CONFIGURED`. The app
  shows its "rates are not connected" state; the server never returns invented
  rates.

## GET /api/v1/market/depth   (login required)
{
  "corridors": [
    {
      "from": "<currency code>",
      "to": "<currency code>",
      "queueDepth": <int>,
      "estimatedSettleSeconds": <int>,
      "status": { "code": "<status code>", "level": "healthy | limited | down" }  (optional)
    }
  ]
}
- Every number is the server's. The app never estimates, smooths or invents
  queue data; without this endpoint the screen says it is not connected.
- `queueDepth` is the number of funded trades in `escrowed`/`matching` on the
  corridor; it is zero or greater. `estimatedSettleSeconds` comes from the
  corridor policy (`p2p_corridors.estimated_settle_seconds`).
- Only enabled corridors with an approved estimate are returned. A corridor
  with no estimate is omitted; the server never invents a wait time.
- Currency codes must exist in /config; corridors naming an unknown code are
  ignored by the app. Corridors appear in the server's order.
- Status codes use the same values and fallback behavior as /rates.

## POST /api/v1/auth/otp/request   (no login)
Request:  { "phone": "+<dial code><national number>" }
Response: { "codeLength": <int>, "resendAfterSeconds": <int>, "expiresInSeconds": <int> }
The app shows the code boxes and the resend countdown from these values.

## POST /api/v1/auth/otp/verify   (no login)
Request:  { "phone": "+<dial code><national number>", "code": "<digits>" }
Response: { "accessToken": "<JWT>", "refreshToken": "<token>",
            "expiresInSeconds": <int>, "profileComplete": <true | false> }
- profileComplete = false sends the merchant to business KYC; true goes Home.
- Wrong or expired codes must be 4xx (not 401) with an error code (below).
- The app stores the refresh token in platform-secure storage (Keychain /
  Android Keystore) at sign-in. It is never kept in app state, logs or
  analytics. The access token stays in memory and is attached to requests.

## Error codes the app already translates (error.code.<lowercase code>)
OTP_INVALID, OTP_EXPIRED, OTP_TOO_MANY_ATTEMPTS, RATE_LIMITED
Any other code falls back to a general message for its HTTP class.

B2.0 adds these stable codes:
UNAUTHORIZED, PROFILE_INCOMPLETE, VALIDATION_FAILED,
IDEMPOTENCY_KEY_REQUIRED, IDEMPOTENCY_KEY_REUSED, IDEMPOTENCY_IN_PROGRESS,
BENEFICIARY_EXISTS, BENEFICIARY_NOT_FOUND, INVALID_RAIL, INVALID_ACCOUNT,
KYC_ALREADY_SUBMITTED, KYC_ALREADY_VERIFIED, ID_NUMBER_ALREADY_USED,
REFRESH_TOKEN_INVALID, REFRESH_TOKEN_EXPIRED, REFRESH_TOKEN_REUSED,
SMS_NOT_CONFIGURED, PRICING_NOT_CONFIGURED, MARKET_DATA_NOT_CONFIGURED,
TRADING_NOT_CONFIGURED, NAME_CHECK_NOT_CONFIGURED.
A `503` with a `*_NOT_CONFIGURED` code means the server is reachable but that
provider is not connected yet. The app must show its unavailable state; it must
not retry as if the data existed.

## PUT /api/v1/me/kyc   (login required)
Request:
{
  "accountType": "personal" | "business",
  "legalName": "<full legal name (personal) or business name (business)>",
  "hubId": "<hub id from /config>",          (business only; omit for personal)
  "idNumber": "<personal: national ID or passport; business: national ID or business TIN>"
}
Response: { "kycStatus": "verified" | "pending" }
- "pending" means a manual or partner check is still running. The user
  still enters Home; the server must refuse transactions until "verified".
- Rejections are 4xx (not 401) with a code the app translates:
  ID_NUMBER_INVALID, ID_NAME_MISMATCH, KYC_REJECTED
- The server verifies the ID/TIN against official registers, stores it
  encrypted, and never returns it in full. Any later display uses a masked
  value (for example the last 4 characters only).
- The app never stores or logs idNumber, and request/response bodies must
  never be logged by any proxy or API gateway either.

## POST /api/v1/auth/refresh   (no login; carries the refresh token)
Request:  { "refreshToken": "<token>" }
Response: { "accessToken": "<JWT>", "refreshToken": "<token>", "expiresInSeconds": <int> }
Used from F5.3 (stay signed in). Refresh tokens rotate on every use.
- The backend stores only a hash of the refresh token.
- The app calls this from one shared single-flight future: a burst of 401s
  produces exactly one rotation, then every waiting request is replayed once
  with the new access token.
- At boot the app reads the stored refresh token, rotates it, and validates the
  profile with `GET /me`; a complete profile opens Home, `PROFILE_INCOMPLETE`
  opens KYC. A network failure keeps the tokens for the next launch.
- Reuse of a rotated token revokes the token family and returns 401 with
  `REFRESH_TOKEN_REUSED`. `REFRESH_TOKEN_INVALID` and `REFRESH_TOKEN_EXPIRED`
  are terminal too: the app clears both stored tokens and asks for a code.
- The app never retries the refresh request itself. The token is single-use, so
  replaying a request whose response was lost would be treated as reuse.

## GET /api/v1/me   (login required)
{
  "id": "<id>", "phone": "+<dial code><number>",
  "accountType": "personal" | "business",
  "displayName": "<name>",
  "hubId": "<hub id>",                         (business only)
  "kycStatus": "verified" | "pending" | "rejected",
  "tier": "<server-defined tier code>",
  "limit": { "currency": "<code>", "dailyLimitMinor": <int>, "dailyUsedMinor": <int> }
}
- `kycStatus` is one of `verified`, `pending` or `rejected`. The database also
  has an internal `not_started` state, but it is never returned here: OTP verify
  sets `profileComplete` false and routes the person to KYC before Home. A
  request made before KYC completes returns `409 PROFILE_INCOMPLETE`.
- `dailyUsedMinor` is derived from trades in the current UTC day that count
  against the limit; it is never a stored wallet balance. Until Product/Finance
  inserts an approved tier limit, `dailyLimitMinor` is `0`.

## Settled rules for endpoints not built yet
- Fees are added ON TOP: totalDebit = amount + fee; the recipient receives the
  full converted amount. Quotes return fee, payout and totalDebit per route.
- There is no wallet and no balance. Home shows "available today" (the
  remaining daily limit). Receiving means payout to the recipient's mobile
  money or bank account.
- Tiers and limits are defined only by the server.

## GET /api/v1/trade/estimate   (login required)
Query: ?sendCurrency=<code>&receiveCurrency=<code>&sendAmountMinor=<int>
Response:
{
  "rate": <number: send-currency units per 1 receive-currency unit>,
  "receiveAmountMinor": <int: the full converted amount; fees are added on top>,
  "estimatedMinSeconds": <int>, "estimatedMaxSeconds": <int>,
  "route": "p2p" | "bank"          (the route this estimate is based on)
}
- Indicative only; the locked price comes with the route choice (quote).
- A safe read: no idempotency key needed, may be retried. The app asks about
  half a second after the person stops typing and ignores out-of-date answers.
- All amounts are whole numbers in the smallest unit (see currency "decimals").

## GET /api/v1/beneficiaries   (login required)
{
  "beneficiaries": [
    { "id": "<id>", "name": "<person or business name>", "railId": "<id from /config>",
      "accountOrPhone": "<number>", "kycVerified": <true | false> }
  ]
}
- A recipient whose railId is not in /config is ignored by the app.

## POST /api/v1/beneficiaries   (login required)
Header: X-Idempotency-Key (one key per create attempt)
Request:
{ "railId": "<id from /config>", "name": "<person or business name>",
  "accountOrPhone": "<number>" }
Response 201: the saved recipient object, exactly as GET /beneficiaries returns it:
{ "id": "<id>", "name": "<name>", "railId": "<id>", "accountOrPhone": "<number>",
  "kycVerified": <true | false> }
- The server validates the rail and the destination format, stores the account
  encrypted and returns only what the owner may see.
- 4xx codes: INVALID_RAIL, INVALID_ACCOUNT, BENEFICIARY_EXISTS, RATE_LIMITED.

## PATCH /api/v1/beneficiaries/{id}   (login required)
Header: X-Idempotency-Key
Request: the same three fields as POST. The server treats the body as the full
editable state, so a retry cannot apply a partial edit twice.
Response 200: the updated recipient object.
- 4xx codes: BENEFICIARY_NOT_FOUND, INVALID_RAIL, INVALID_ACCOUNT,
  BENEFICIARY_EXISTS, RATE_LIMITED.
- Only the owner can read or change a recipient. A non-owner gets 404, never a
  hint that the id exists.

## DELETE /api/v1/beneficiaries/{id}   (login required)
Header: X-Idempotency-Key
Response 204 with no body. Deletion is a soft delete server-side and repeated
requests for the same owned recipient stay successful so a retry is safe.
- A non-owner gets 404. The server never deletes a trade snapshot because a
  recipient was removed.

## POST /api/v1/trade/quote   (login required)
Request:  { "sendCurrency": "<code>", "receiveCurrency": "<code>", "sendAmountMinor": <int> }
Response:
{
  "id": "<quote id>",
  "rate": <number: send-currency units per 1 receive-currency unit>,
  "serverTime": "<ISO-8601 UTC: the server's clock when it answered>",
  "expiresAt": "<ISO-8601 UTC: when the rate lock ends>",
  "routes": [
    {
      "route": "p2p" | "bank",
      "feeBps": <int>,
      "feeMinor": <int, send currency>,
      "payoutMinor": <int, receive currency: the FULL converted amount>,
      "totalDebitMinor": <int, send currency: amount + fee>,
      "estimatedMinSeconds": <int>, "estimatedMaxSeconds": <int>,
      "isRecommended": <bool>, "isAvailable": <bool>,
      "matchingDensityPercent": <0-100, optional>,
      "status": { "code": "<status code>", "level": "healthy | limited | down" },   (optional)
      "safeguardCode": "<code>",     (optional: only when the safeguard really exists)
      "breakdown": [ { "code": "platform_fee | network_fee | ...", "amountMinor": <int, send currency> } ]
    }
  ]
}
- The lock lasts until expiresAt; nothing in the app assumes a duration. The
  app corrects its countdown with serverTime, so a wrong phone clock cannot
  stretch or cut the lock.
- While new quotes are paused by an operator, the endpoint returns
  `503 SERVICE_PAUSED` with the operator message. Rates and estimates remain
  available.
- Fees are added on top: totalDebitMinor = sendAmountMinor + feeMinor, and
  payoutMinor is never reduced by fees.
- Codes the app translates today. Route status: high_matching_density,
  instant_settlement_available. Safeguard: local_partner_escrow,
  direct_bank_treasury (wording must be approved by the lawyer; the server
  must send a safeguardCode only when that safeguard truly exists). Fee lines:
  platform_fee, network_fee. Unknown codes are ignored (safeguards) or shown
  generically (fee lines).
- Rejections are 4xx with a code, e.g. CORRIDOR_UNAVAILABLE, LIMIT_EXCEEDED,
  VERIFICATION_REQUIRED.
- A locked rate is a promise the platform keeps even if the market moves: the
  spread built into the rate must cover that risk (a pricing decision).

## Payout rails now carry a kind
In GET /config, each payoutRails entry gains:  "kind": "mobile_money" | "bank"
The app labels the field ("mobile number" or "account number") and formats it
from this. The recipient's destination is the country of the currency being
received; the app lists only rails whose countryCode matches.

## POST /api/v1/beneficiaries/check   (login required)
Request:  { "railId": "<rail id>", "account": "<international number or account>", "name": "<optional>" }
Response:
{
  "accountStatus": "found" | "not_found",
  "networkName": "<e.g. the mobile money network>",          (optional)
  "nameMatch": "match" | "mismatch" | "unavailable"          (only when a name was sent)
}
- The registered name is NEVER returned: only whether the name matches.
  Otherwise the endpoint could be used to read other people's names.
- The server must throttle this endpoint per person (enumeration protection)
  and never log the account or the name.
- "unavailable" means the destination cannot check names automatically (for
  example some banks). The app then allows paying but warns the person.
- Rejections are 4xx with a code, e.g. RATE_LIMITED, RAIL_UNAVAILABLE.
- Until a destination name-check provider is connected, the endpoint returns
  `503 NAME_CHECK_NOT_CONFIGURED`.

## Authorization attempts (used by the payment step, F3.4)
The app creates ONE unique key per authorization attempt (same quote and same
recipient details keep the same key) and sends it as X-Idempotency-Key on
POST /api/v1/trade/initiate and on every retry. The server must return the
original result for a repeated key and must never charge twice.

## POST /api/v1/trade/initiate   (login required)
Header:   X-Idempotency-Key = the app's ONE key for this authorization attempt
Request:
{
  "quoteId": "<quote id>", "route": "p2p" | "bank",
  "recipient": { "railId": "<id>", "account": "<number>", "name": "<name>", "reference": "<optional>" }
}
Response:
{
  "trade": <trade object, below>,
  "collection": {
    "pushSent": <bool: a payment prompt was sent to the payer's phone>,
    "networkName": "<payer's mobile money network>",          (optional)
    "amountMinor": <int: the total to pay, send currency>,
    "pushTimeoutSeconds": <int: when the app opens the manual fallback>,
    "pollIntervalSeconds": <int: how often the app checks the trade>,
    "manual": { "methodCode": "paybill | till | ...", "number": "<number>", "reference": "<code>" }   (optional)
  }
}
- A repeated key MUST return the original result and never start a second
  collection. A different quote or different recipient details are a new key.
- Rejections are 4xx with a code: QUOTE_EXPIRED, LIMIT_EXCEEDED,
  VERIFICATION_REQUIRED, RECIPIENT_REJECTED, CORRIDOR_UNAVAILABLE.
- A provider outage is `503 PAYMENT_PROVIDER_UNAVAILABLE`; a provider rejection
  keeps its own 4xx code. The quote is not consumed on either failure.
- With `PAYMENT_PROVIDER=disabled`, initiate returns
  `503 PAYOUT_NOT_CONFIGURED`; it never starts a simulated collection. Estimate
  and quote require a configured pricing provider and return
  `503 PRICING_NOT_CONFIGURED` without one.
- While new trades are paused by an operator, initiate returns
  `503 SERVICE_PAUSED` with the operator message and does not consume the quote.
  Existing payouts, refunds and matches continue.

Trade object:
{
  "id", "reference", "route": "p2p | bank",
  "status": "pending_deposit | escrowed | matching | matched | disbursing |
             completed | expired | refunded | failed | cancelled",
  "sendCurrency", "receiveCurrency", "sendAmountMinor", "feeMinor", "feeBps",
  "receiveAmountMinor", "rate", "beneficiaryName", "createdAt": "<ISO-8601 UTC>",
  "verificationHash": "<optional>"
}

## GET /api/v1/trades/{id}   (login required)  -> trade object
The app checks this every pollIntervalSeconds. "pending_deposit" means keep
waiting; escrowed or later means the deposit arrived (the SERVER decides, from
the payment aggregator's callback); expired, refunded, failed or cancelled
means it did not complete. (Live push updates may replace polling later.)

## POST /api/v1/trades/{id}/payment-claim   (login required)
The payer says they paid manually. This only asks the server to re-check the
aggregator now; it never marks anything as paid by itself. The app sends
X-Idempotency-Key and must get the original result for a repeated key. The
response body is not used; the payment step keeps polling GET /trades/{id}.

## POST /api/v1/trades/{id}/cancel   (login required)  -> trade object
4xx codes: CANNOT_CANCEL, ALREADY_PAID (the app then keeps watching the trade).

## POST /api/v1/trades/{id}/disburse   (login required)
Header: X-Idempotency-Key
Response:
{
  "trade": <trade object>,
  "payout": {
    "id": "<uuid>", "status": "pending | submitted | paid | failed",
    "providerReference": "<provider id>", "amountMinor": <int>,
    "currency": "<ISO code>"
  }
}
- `202` means the payout is submitted and the app should keep polling the
  trade; `200` means it is terminal (`completed` or `refunded`).
- Only an escrowed/matched trade with a mobile-money rail can be disbursed.
  A bank rail returns `503 PAYOUT_RAIL_NOT_CONFIGURED` until a partner account
  contract exists.
- A provider rejection refunds the payer before the error is returned. A
  provider outage leaves the trade retryable.

## POST /api/v1/trades/{id}/refund   (login required)
Header: X-Idempotency-Key
Request (all optional):
{ "reason": "customer_request" }
Response:
{
  "trade": <trade object, status "refunded" or "cancelled">,
  "refund": { "id": "<uuid>", "status": "paid | failed | pending",
              "providerReference": "<provider id>", "amountMinor": <int>,
              "currency": "<ISO code>" }
}
- The provider must confirm the refund before any ledger line is reversed.
- 4xx codes: NOT_REFUNDABLE, CANNOT_REFUND, PAYOUT_ALREADY_SENT.
- A collection that arrives after cancellation is booked and refunded; the
  trade stays `cancelled` and the refund records the return.

## POST /api/v1/trades/{id}/match   (login required; server/ops trigger)
Header: X-Idempotency-Key
Response:
{
  "matched": <bool>,
  "expired": <bool, optional>,
  "trade": <trade object>,
  "match": {
    "id": "<uuid>", "status": "locked | released | failed",
    "rate": <number|null>, "buyCurrency": "<code>", "sellCurrency": "<code>",
    "buyAmountMinor": <int>, "sellAmountMinor": <int>,
    "liquidity": <bool: true when an LP order is the counterparty>,
    "matchedAt": "<ISO-8601 UTC|null>", "releasedAt": "<ISO-8601 UTC|null>"
  }   (optional)
}
- `200` means matched or expired/refunded; `202` means still queued.
- Only funded mobile-money trades enter the queue. Matching is disabled by
  default (`503 MATCHING_DISABLED`).
- No counterparty identity is ever returned.

## POST /api/v1/matches/{id}/disburse   (login required; one leg's owner)
Header: X-Idempotency-Key
Response:
{
  "match": <match object>,
  "legs": [ { "trade": <trade object>, "payout": <payout object> } ]
}
- Pays or resumes both legs. Safe to retry after a provider outage.
- A first-leg failure refunds both legs; a second-leg failure refunds the
  second leg and books a treasury compensation entry.
- 4xx codes: MATCH_NOT_FOUND, MATCH_NOT_DISBURSABLE, MATCHING_DISABLED.

## Admin ops surface   (Phase A; not used by the app)
Header: `x-admin-key: <ADMIN_API_KEY>`
- `GET /api/v1/admin/overview` — corridors, queue, locked matches, pending
  payouts/refunds, LP orders and alerts. Amounts are separate per currency.
- `PATCH /api/v1/admin/corridors/{from}/{to}` — enable/disable, exposure cap,
  min/max amount, match deadline, estimated settle seconds, spread metadata.
- `POST /api/v1/admin/trades/{id}/match` — one FIFO/LP attempt.
- `POST /api/v1/admin/matches/{id}/disburse` — resume the payout.
- `POST /api/v1/admin/liquidity/providers`,
  `PATCH /api/v1/admin/liquidity/providers/{id}` — allowlist/suspend an LP.
- `GET|POST /api/v1/admin/liquidity/orders`,
  `PATCH /api/v1/admin/liquidity/orders/{id}` — prefunded standing orders;
  creating one requires `prefundReference` and books the prefund.
- The HTML shell is `/admin`; it asks for the key and stores it in
  `sessionStorage`.
- Missing `ADMIN_API_KEY` → `503 ADMIN_NOT_CONFIGURED`; wrong key → `401`.
- `admin_audit_log` is append-only and records every write. This is a break-glass
  Phase A surface; the final admin identity/RBAC/bookkeeping plan is
  `docs/ADMIN_PANEL_PLAN.md`.

## POST /api/v1/webhooks/payments/{provider}   (provider only)
Headers: X-Kachi-Timestamp, X-Kachi-Signature
The signature is HMAC-SHA256 over `<timestamp>.<exact raw body>` with the
per-provider secret. The endpoint is public only because the HMAC is the
authentication; a missing, stale or invalid signature is `401`.
- Collection callbacks carry `checkoutRequestId`, `status`, `amountMinor` and
  `currency`; payout callbacks carry `payoutId` instead.
- The provider's current status is re-read and validated before booking.
- `(provider, provider_event_id)` is unique, so a replayed callback returns
  `200 { "received": true, "replay": true }` and moves no money twice.
- With no `PAYMENT_WEBHOOK_SECRET`, the endpoint returns
  `503 WEBHOOKS_NOT_CONFIGURED`.

## GET /api/v1/trades/{id}/invoice   (login required)
{
  "tradeId": "<trade id>",
  "qrCodeUrl": "<https URL for the invoice QR image>",
  "shareUrl": "<https URL a payer can open>",
  "validUntil": "<ISO-8601 UTC>",
  "amountMinor": <int, amount the payer must pay>,
  "currency": "<ISO currency code of amountMinor>"
}
- The server issues both URLs and controls `validUntil`; the app never builds
  or extends an invoice link. One trade has one invoice; repeated calls return
  the same link while it is valid.
- Links live for 72 hours and are available only while the trade is active
  (pending deposit through disbursing).
- `amountMinor` is the total debit in the send currency (amount + fee); the app
  formats it with the currency's `decimals` from `/config`.
- 4xx codes: TRADE_NOT_FOUND, INVOICE_NOT_AVAILABLE, INVOICE_EXPIRED.
- 503 `INVOICE_NOT_CONFIGURED` means the server has no `PUBLIC_API_URL`.

## GET /pay/{token}   (no login; public payer page)
Human-readable HTML page with the amount, currency, trade reference and expiry.
It states plainly when a link is expired or not found. It does not accept card
details or move money.

## GET /api/v1/invoices/{token}/qr.png   (no login)
PNG QR code encoding the public `shareUrl`. 404 `INVOICE_NOT_FOUND`,
410 `INVOICE_EXPIRED`, 503 `INVOICE_NOT_CONFIGURED`.

## POST /api/v1/trades/{id}/share   (login required)
Header: X-Idempotency-Key
Response:
{
  "shareUrl": "<https URL a payer can open>",
  "validUntil": "<ISO-8601 UTC>",
  "verificationHash": "<server-issued hash>"
}
- The response carries a shareable link and its metadata. A repeated key
  returns the original result and does not create a second link.
- 4xx codes: TRADE_NOT_FOUND, INVOICE_NOT_AVAILABLE, INVOICE_EXPIRED,
  RATE_LIMITED.

## GET /api/v1/trades   (login required)
```
{ "trades": [ <trade object> ] }
```
Newest first. The app currently reads the whole list and filters date windows on
the device; a future `nextCursor` can be added without changing this shape.

## GET /api/v1/trades/{id}/history   (login required)
```
{ "events": [ { "status": "<status code>", "at": "<ISO-8601 UTC>",
                "noteCode": "<optional code>" } ] }
```
Oldest first. The app renders the events in the order received. `noteCode` is
optional and not displayed yet; an unknown value is ignored while the status
label is still shown. An unknown `status` means the response is broken and the
timeline says so plainly. The endpoint must never invent a step for the app.

## GET /api/v1/trades/analytics   (login required)
```
{
  "totals": { "trades": <int>, "sentMinor": <int>, "sentCurrency": "<code>",
              "receivedMinor": <int>, "receivedCurrency": "<code>" },
  "corridors": [ { "from": "<code>", "to": "<code>",
                   "trades": <int>, "sentMinor": <int> } ]
}
```
Every number is calculated by the server. Currency codes must exist in /config;
an unknown code means the response is broken. Corridors are shown in the
server's order.
- Only completed trades are counted.
- `sentCurrency` is the account's limit/reporting currency. The totals cover
  the highest-volume receive currency, because the contract has one received
  currency and minor units are never summed across currencies. Corridors list
  every receive currency in their own currency.
- `GET /api/v1/trades/export` returns `503 EXPORT_NOT_CONFIGURED` when
  `PUBLIC_API_URL` is empty.

## GET /api/v1/trades/export   (login required)
```
{ "downloadUrl": "<one-time link>", "expiresAt": "<ISO-8601 UTC>" }
```
The file is built and served by the server; the app only hands the link over
and copies it with the built-in clipboard. No new dependency.
The link is a five-minute, single-purpose token for that user and is public
only because the token is the authentication.
