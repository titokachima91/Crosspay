import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crosspay_app/core/security/biometric_manager.dart';

/// F5.3 — local app-lock PIN manager.
///
/// The PIN itself is NEVER stored: only a salted SHA-256 hash is kept
/// in platform-secure storage (Keychain / Keystore). A wrong device
/// clock, a cleared app or a restored phone simply asks the person to
/// set the PIN again. Server-side session security stays on the server
/// (refresh tokens, timeouts) — this lock only guards the app surface.
class PinManager {
  PinManager([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _keyHash = 'crosspay_pin_hash';
  static const _keySalt = 'crosspay_pin_salt';

  final FlutterSecureStorage _storage;

  /// True when a lock PIN has been set on this device.
  Future<bool> hasPin() async {
    final hash = await _storage.read(key: _keyHash);
    return hash != null && hash.isNotEmpty;
  }

  /// Sets (or replaces) the app-lock PIN.
  /// Returns false when the PIN is too weak (shorter than 4 digits).
  Future<bool> setPin(String pin) async {
    if (pin.length < 4) return false;
    final salt = _randomSalt();
    final hash = _hash(pin, salt);
    await _storage.write(key: _keySalt, value: salt);
    await _storage.write(key: _keyHash, value: hash);
    return true;
  }

  /// Verifies a PIN against the stored hash. Constant false on no-PIN.
  Future<bool> verify(String pin) async {
    final salt = await _storage.read(key: _keySalt);
    final stored = await _storage.read(key: _keyHash);
    if (salt == null || stored == null) return false;
    return _hash(pin, salt) == stored;
  }

  /// Removes the app lock (used when the person turns the lock off).
  Future<void> clear() async {
    await _storage.delete(key: _keyHash);
    await _storage.delete(key: _keySalt);
  }

  /// Gate used by the app shell: offers biometrics when the device supports
  /// them, then falls back to the PIN dialog. Returns true when unlocked (or
  /// when no PIN is set). Cancelling the PIN dialog leaves the shell.
  Future<bool> ensureUnlocked(
    BuildContext context, {
    BiometricManager? biometrics,
    String? biometricReason,
  }) async {
    if (!await hasPin()) return true;

    final manager = biometrics ?? BiometricManager();
    if (await manager.isAvailable()) {
      final unlocked = await manager.authenticate(
        localizedReason: biometricReason ?? 'Confirm with fingerprint or face',
      );
      if (unlocked) return true;
      if (!context.mounted) return false;
      // Denied or cancelled: the PIN dialog is still available.
    }

    while (true) {
      if (!context.mounted) return false;
      final entered = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final controller = TextEditingController();
          String? error;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
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
                decoration: InputDecoration(
                  labelText: 'PIN',
                  errorText: error,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, null),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    if (controller.text.length < 4) {
                      setDialogState(() => error = 'Use at least 4 digits');
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
      );
      if (entered == null) return false;
      if (await verify(entered)) return true;
      // Wrong PIN: loop again with an error on the next dialog.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong PIN')),
        );
      }
    }
  }

  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  String _randomSalt() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return sha256.convert(utf8.encode('$now:${now * 7}')).toString();
  }
}
