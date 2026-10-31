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

Only the founder can do (open items)
- Hire a local financial-regulation lawyer BEFORE any public launch: licensing
  for consumer transfers, the "non-custodial" claim, KYC privacy notice
  wording, privacy policy, data-protection registration in each country.
- Run the pilot through a licensed bank / payment partner.
- Choose the final name (BantuPay / CrossPay / AfrEX); check domain and trademark.
- Open partner conversations: SMS provider, mobile money aggregators, bank.
- Supply a logo file and the privacy policy text.
