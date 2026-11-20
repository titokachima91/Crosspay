import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A request to lock the signed-in shell without ending the session.
///
/// The value only changes; the shell listens for a new request, hides its
/// content and runs the PIN/biometric gate again. This is deliberately
/// separate from sign-out, which clears and revokes the refresh token.
class AppLockNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void lock() => state++;
}

final appLockProvider = NotifierProvider<AppLockNotifier, int>(
  AppLockNotifier.new,
);
