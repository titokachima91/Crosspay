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
- Home is still a temporary screen until F3.1.

To remove all simulated data: delete this folder.
