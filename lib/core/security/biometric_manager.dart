import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/material.dart';

/// F5.3 - biometric unlock manager (fingerprint / face).
///
/// Returns the current auth status, runs an unlock attempt, and falls back to
/// the local PIN manager when biometrics are unavailable or denied.
///
/// On platforms without biometric support (web) or where the plugin has no
/// platform implementation, every call degrades gracefully: unlock becomes
/// "unavailable" and the gate falls back to the PIN dialog.
class BiometricManager {
  BiometricManager();

  /// True when the device currently offers biometrics.
  Future<bool> isAvailable() async {
    try {
      final localAuth = LocalAuthentication();
      final types = await localAuth.getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// True when the current authentication (fingerprint/face) succeeds.
  /// False on denial, cancellation, or when unavailable.
  Future<bool> authenticate({required String localizedReason}) async {
    try {
      final localAuth = LocalAuthentication();
      final ok = await localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: true,
        ),
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Biometric unlock -> fall back to the PIN gate if denied/unavailable.
  Future<bool> unlock(
    BuildContext context,
    Future<bool> Function(String pin) verifyPin,
  ) async {
    if (await isAvailable()) {
      final ok = await authenticate(localizedReason: 'Confirm with fingerprint or face');
      if (ok) return true;
    }
    // Fall back to the plain PIN dialog.
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final controller = TextEditingController();
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Enter PIN'),
            content: TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              onSubmitted: (v) => Navigator.pop(dialogContext, v),
              decoration: InputDecoration(labelText: 'PIN', errorText: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  if (controller.text.length < 4) {
                    setState(() => error = 'Use at least 4 digits');
                    return;
                  }
                  Navigator.pop(dialogContext, controller.text);
                },
                child: const Text('Unlock'),
              ),
            ],
          ),
        );
      },
    ) ?? false;
  }
}