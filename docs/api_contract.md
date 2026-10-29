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
