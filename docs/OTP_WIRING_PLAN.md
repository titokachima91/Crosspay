# OTP wiring plan

**Status**: CrossPay OTP endpoints, the HTTP SMS adapter and the sandbox
real-SMS path are built 2026-11-15. Real SMS is opt-in and allowlisted.
**Provisional sender**: `+255767304776` (from local `0767304776`), Tanzania.
This is the SIM/device number for the current sandbox gateway, not a recipient
and not a secret.
**First real test**: sent through the sandbox to `+255714604777` on
2026-11-15; the API response contained no code.

---

## 1. What is already wired

The Flutter app already has the complete OTP screens and calls:

- `POST /api/v1/auth/otp/request`
- `POST /api/v1/auth/otp/verify`

The CrossPay API already implements:

- six-digit code generation;
- HMAC-SHA-256 code storage, never plaintext;
- five-minute expiry and five attempts;
- new code supersedes older unused codes;
- per-phone and per-IP database rate limits;
- rotating refresh tokens after verification;
- `503 SMS_NOT_CONFIGURED` when delivery is disabled.

The sandbox facade also has OTP and shows `sandboxCode` on the dashboard for
local demos. That is a sandbox convenience; production must never return it.

What was missing was real delivery from the CrossPay API. That is now provided
by `HttpSmsSender`.

---

## 2. Delivery path

```
Flutter app
  │ POST /auth/otp/request { phone }
  ▼
CrossPay API
  ├── rate limit phone + IP
  ├── create hashed OTP challenge
  ├── SmsSender.sendOtp(phone, code)
  ▼
HttpSmsSender
  │ POST SMS_API_URL
  │ { recipient, message, senderId? }
  │ x-api-key: SMS_API_KEY
  ▼
Sandbox /v1/send-sms  (or a real gateway)
  ▼
TextBee / Android gateway / SMS partner
  ▼
Payer's phone
```

Verification stays entirely in CrossPay:

```
Flutter app
  │ POST /auth/otp/verify { phone, code }
  ▼
CrossPay API
  ├── rate limit
  ├── compare HMAC hash, attempts, expiry, supersession
  ├── issue access + refresh tokens
  ▼
App
```

The code is never returned by the API, never logged and never stored in
plaintext. The sandbox `sandboxCode` field exists only in the sandbox facade.

---

## 2b. Sandbox real-SMS path

The sandbox facade can now send the OTP through the existing protected
`/v1/send-sms` route:

```bash
FACADE_SMS_DELIVERY=true
SMS_ALLOWED_RECIPIENTS=+255714604777
FACADE_SMS_SENDER_PHONE=+255767304776
SMS_GATEWAY_URL=http://127.0.0.1:8080/v1/send-sms
# SMS_GATEWAY_KEY defaults to API_KEY_CROSSPAY
```

When enabled:

- the facade calls `/v1/send-sms` as the **CrossPay tenant**;
- the API response does **not** include `sandboxCode`;
- the dashboard OTP table hides the code;
- the recipient must be on `SMS_ALLOWED_RECIPIENTS`;
- a gateway failure returns `503 SMS_DELIVERY_FAILED` and invalidates the code;
- a non-allowlisted number returns `403 SMS_RECIPIENT_NOT_ALLOWED`.

### Multi-tenant boundary

- The protected SMS/AI files are unchanged.
- The call uses `API_KEY_CROSSPAY`; GasLink is never used for CrossPay OTP.
- GasLink routes, keys, data and workers remain in place.
- The SMS gateway route stays shared and authenticates each tenant by key.
- No tenant data is deleted or overwritten.
- The OTP allowlist is a sandbox cost/safety control, not a tenant boundary.

---

## 3. Configuration

```bash
# CrossPay API
SMS_PROVIDER=http
SMS_API_URL=http://127.0.0.1:8080/v1/send-sms
SMS_API_KEY=<sandbox API_KEY_CROSSPAY>
SMS_SENDER_ID=CROSSPAY
SMS_TIMEOUT_MS=5000

# Documentation / gateway check only; the Android SIM is configured on the
# device. Do not hardcode this number in application code.
SMS_GATEWAY_PHONE=+255767304776
```

Default remains:

```bash
SMS_PROVIDER=disabled
```

That keeps the honest `503 SMS_NOT_CONFIGURED` state until the operator
deliberately connects a gateway.

The sandbox `/v1/send-sms` route is a compatible HTTP gateway. A real partner
with a different request shape should get its own `SmsSender` adapter; do not
bend `HttpSmsSender` into a provider-specific client.

---

## 4. Provisional sender rules

- `+255767304776` is the current sending SIM/device.
- It is not a recipient number and must not be used as a test payer.
- It is configured on the Android gateway/TextBee device, not in CrossPay
  source code.
- Do not commit the gateway API key, device ID or SIM credentials.
- If the SIM changes, update the gateway and `SMS_GATEWAY_PHONE`; no code
  change is required.
- SMS costs and per-market sender-ID rules are an operator responsibility.

---

## 5. Failure behaviour

| Case | Result |
|---|---|
| `SMS_PROVIDER=disabled` | `503 SMS_NOT_CONFIGURED`; challenge superseded, no code returned |
| Gateway unreachable | `503 SMS_DELIVERY_FAILED`; challenge superseded |
| Gateway returns non-2xx | `503 SMS_DELIVERY_FAILED` |
| Gateway returns `{ success: false }` | `503 SMS_DELIVERY_FAILED` |
| Gateway timeout | `503 SMS_DELIVERY_FAILED` |
| Wrong code | `422 OTP_INVALID` |
| Expired code | `422 OTP_EXPIRED` |
| Too many attempts | `422 OTP_TOO_MANY_ATTEMPTS` |
| Reused/superseded code | `422 OTP_INVALID` |

No path writes the code into logs or the response.

---

## 6. Tests

Built:

- `test/http-sms.test.ts`:
  - posts recipient/message/senderId and `x-api-key`;
  - maps non-2xx to `SMS_DELIVERY_FAILED`;
  - rejects HTTP 200 `{ success: false }`;
  - accepts a plain 2xx response;
  - times out an unresponsive gateway;
  - never includes the code in the error.
- `test/http-bootstrap.test.ts`:
  - disabled provider returns `SMS_NOT_CONFIGURED`;
  - HTTP provider delivers a real code to a local gateway and the code verifies;
  - the response does not contain the code.
- Existing rate-limit and refresh-rotation tests still pass.

CrossPay API suite: **53/53**, 12 suites.
Sandbox suite: **36/36**, including the real-SMS allowlist/failure path.

---

## 7. Production checklist

- Choose the SMS partner and per-market sender ID.
- Register the sender and complete KYC/compliance for each country.
- Add delivery receipts and retry policy.
- Add monitoring for send failures, latency and per-country delivery rate.
- Keep per-phone/per-IP rate limits.
- Never log the code or the full phone number.
- Keep `sandboxCode` and the sandbox OTP panel out of production.
- Store gateway credentials only in host settings.
- Add a provider-specific adapter if the partner's API is not
  `{ recipient, message }` + `x-api-key`.

---

## 8. Remaining work

1. Configure the gateway with the provisional SIM `+255767304776`.
2. Run a live OTP request from the app through CrossPay → sandbox `/v1/send-sms`.
3. Confirm the SMS arrives and verification issues tokens.
4. Replace the sandbox gateway with the chosen SMS partner before launch.
5. Add delivery monitoring and retry/fallback policy.
