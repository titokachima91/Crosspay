package com.yourname.crosspay_app

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth (fingerprint / face) requires a FragmentActivity host on Android.
// A plain FlutterActivity compiles but biometric authentication fails at
// runtime, so this must stay FlutterFragmentActivity.
class MainActivity : FlutterFragmentActivity()
