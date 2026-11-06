# CrossPay preview app (simulated data)

Run:  flutter run -d chrome -t preview/main.dart

This is NOT the real app. It runs the real screens against simulated data so
you can walk the whole flow without a server. Every screen shows a yellow
"PREVIEW" strip. All simulated values live in this folder only.

Walkthrough
- Splash: simulated corridors appear. Tap "Get started".
- Phone: any 9 digits. Starting with 71 to 74 shows "Preview Network A".
- Code: 1234 works; anything else shows the wrong-code message.
- Identity: try Personal and Business. An ID containing "bad" is rejected,
  one containing "wait" ends as pending, anything else is verified.
- Home: your name and badge come from what you typed. Type an amount in
  "You send"; the other side updates after a short pause. Tap the rate line
  to swap currencies; tap a saved recipient to select it. More than
  "Available today" (8,000,000 TZS) shows the limit message. A "pending"
  registration shows the verification message and the button stays off.
- Ledger, Rates and Account tabs, and the screen after "Review", are still
  temporary placeholders.

To remove all simulated data: delete this folder.

Route selection (preview)
- Tap "Review and select route" on Home. The simulated lock lasts 90 seconds,
  so you can watch it expire and tap "Get a new rate".
- Amounts above 5,000,000 make the simulated bank route unavailable.
- "Proceed" leads to a temporary screen until F3.3.

Recipient details (preview)
- After choosing a route, "Proceed" opens the recipient screen. Try the two
  payout methods of the destination country.
- A mobile number ending in 0 is "not found". A name containing "mismatch"
  does not match; "unverifiable" cannot be checked automatically; bank
  accounts cannot have their name checked automatically; any other name matches.
- Tap a saved recipient on Home first to see the prefill.
- "Authorize payment" leads to a temporary screen until F3.4.

Payment prompt (preview)
- "Authorize payment" opens the payment screen. By default the simulated
  deposit arrives after about three checks (roughly 6 seconds) and you move on
  to a temporary screen.
- Type "timeout" in the payment reference: the deposit never confirms by
  itself; the manual details open after about 12 seconds, and "I have
  completed manual payment" confirms it at the next check.
- Type "nopush" in the payment reference: no prompt is sent and the manual
  details are shown at once.
- "Cancel transaction" asks for confirmation, then returns Home.
