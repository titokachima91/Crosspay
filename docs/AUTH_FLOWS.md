# Authentication and account lifecycle

One phone number = one CrossPay account. The phone is the identity; OTP proves
possession of it. There is no second account on the same number.

## Entry points

When there is no stored session:

- **Sign in** — existing account
- **Create account** — the former “Get started”, for a new number

Both use the same phone → OTP path. The label changes copy and the
post-verification message, not the server identity model.

After OTP verification:

| Server result | App destination |
|---|---|
| New account | KYC / registration |
| Existing account, profile complete | Home |
| Existing account, KYC pending | KYC status |
| Existing account, KYC rejected | KYC resubmission |
| Existing account selected via “Create account” | Info message, then the existing account; never a duplicate |
| New account selected via “Sign in” | Info message, then KYC; the OTP proved the phone |

`POST /auth/otp/verify` returns `isNewUser` for the message. Older servers that
omit it default to false; routing still uses `profileComplete`.

## OTP triggers

Required:

- no stored refresh token (first install, reinstall, secure storage lost)
- explicit sign-out or switch account
- refresh token expired, invalid or reused
- new device
- account recovery or phone-number change
- admin-forced session revocation
- a future risk/security signal

Not required:

- app restart with a stored refresh token
- background/foreground
- Lock now
- tab changes

## Lock vs sign-out vs switch

| Action | Session | Refresh token | Local PIN/biometric | Next entry |
|---|---|---|---|---|
| Background / Lock now | kept | kept | kept | biometric/PIN |
| Sign out | ended | family revoked | cleared | OTP |
| Switch account | ended | family revoked | cleared | OTP for the other phone |

Clearing the local lock on sign-out/switch is deliberate: a different account
must not be unlocked by the previous person's fingerprint or PIN. The account,
KYC, history and beneficiaries are not deleted.

A later upgrade can namespace the local lock by account id so the same person
keeps their PIN/biometric setup across switches. V1 uses clear-on-switch.

## Deleted accounts

Deletion is a support/compliance action, not a self-service button.

- The account is disabled and soft-deleted; sessions are revoked.
- The phone number stays bound for the KYC/AML retention period.
- A 30-day restore window lets the same phone recover the account with OTP and
  normal identity checks.
- After the window, the account remains archived; reusing the phone for a new
  account requires compliance approval and fresh KYC.
- A person who later receives a recycled SIM cannot take over the old account;
  OTP alone does not bypass the tombstone.

The current `users` row uses `deleted_at` and the unique phone constraint, so a
deleted account already blocks automatic re-registration and returns
`ACCOUNT_DISABLED` on OTP verification.

## Account switching

1. Confirm the switch.
2. Revoke the current refresh-token family (`POST /auth/logout`).
3. Clear local tokens.
4. Clear the local PIN/biometric preference.
5. Return to the start screen, where Sign in is available.
6. Require OTP for the other phone.

The server supports multiple sessions on different devices; switching on one
device revokes only that device's family.

## Account loss protections

- The account is server-side and phone-bound; reinstalling or signing out never
  deletes it.
- OTP restores access on the bound phone.
- Lost SIM/phone is handled by support with identity/KYC checks, not by creating
  a new account.
- Sign-out/switch clears only tokens and the local lock.
- Account deletion has a restore window and a reserved phone.
- Support can revoke a customer's sessions from Customer 360.
