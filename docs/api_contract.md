# CrossPay API contract (working draft)

Conventions
- Base path: /api/v1
- Money: whole integers in minor units (1/100). Times: ISO-8601 UTC.
- Writes carry X-Idempotency-Key; the server must honor it.
- Errors: { "error": { "code": "SOME_CODE", "message": "for logs" } }
- Endpoints marked "no login" must work without a token.

## GET /api/v1/config   (no login)
{
  "currencies":  [ { "code": "<ISO code>", "name": "<name>", "countryCode": "<2 letters>" } ],
  "hubs":        [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>" } ],
  "payoutRails": [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>" } ],
  "countries":   [ { "code": "<2 letters>", "name": "<name>", "dialCode": "<digits, e.g. 255>",
                     "nationalNumberLength": <digits after the dial code, no leading zero> } ],
  "carriers":    [ { "id": "<id>", "name": "<name>", "countryCode": "<2 letters>",
                     "prefixPattern": "<regex matched from the START of the national number>" } ]
}
All five lists are required (they may be empty). The first country listed is
the default on the phone screen. Carrier matching is a suggestion only.

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

## POST /api/v1/auth/otp/request   (no login)
Request:  { "phone": "+<dial code><national number>" }
Response: { "codeLength": <int>, "resendAfterSeconds": <int>, "expiresInSeconds": <int> }
The app shows the code boxes and the resend countdown from these values.

## POST /api/v1/auth/otp/verify   (no login)
Request:  { "phone": "+<dial code><national number>", "code": "<digits>" }
Response: { "accessToken": "<JWT>", "profileComplete": <true | false> }
- profileComplete = false sends the merchant to business KYC; true goes Home.
- Wrong or expired codes must be 4xx (not 401) with an error code (below).
- Token lifetime and refresh are NOT defined yet. For now an expired token
  (401 on a request that carried a token) signs the user out.

## Error codes the app already translates (error.code.<lowercase code>)
OTP_INVALID, OTP_EXPIRED, OTP_TOO_MANY_ATTEMPTS, RATE_LIMITED
Any other code falls back to a general message for its HTTP class.

## PUT /api/v1/me/kyc   (login required)
Request:  { "businessName": "<name>", "hubId": "<hub id from /config>", "idNumber": "<national ID or business TIN>" }
Response: { "kycStatus": "verified" | "pending" }
- "pending" means a manual or partner check is still running. The merchant
  still enters Home; the server must refuse transactions until "verified".
- Rejections are 4xx (not 401) with a code the app translates:
  ID_NUMBER_INVALID, ID_NAME_MISMATCH, KYC_REJECTED
- The server verifies the ID/TIN against official registers, stores it
  encrypted, and never returns it in full. Any later display uses a masked
  value (for example the last 4 characters only).
- The app never stores or logs idNumber, and request/response bodies must
  never be logged by any proxy or API gateway either.
