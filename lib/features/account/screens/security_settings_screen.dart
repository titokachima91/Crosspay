import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/security/app_lock_provider.dart';
import 'package:crosspay_app/core/security/biometric_manager.dart';
import 'package:crosspay_app/core/security/pin_manager.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F5.3 Security settings — app-lock PIN, biometric unlock, sign out.
///
/// The PIN is hashed locally (never stored raw, never sent anywhere).
/// Biometrics are offered by the shell gate when the device supports them;
/// the PIN always remains the fallback. The refresh token lives in the same
/// platform-secure storage and rotates on every use.
class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({
    super.key,
    this.pinManager,
    this.biometrics,
  });

  /// Test seams; production uses the secure-storage-backed defaults.
  final PinManager? pinManager;
  final BiometricManager? biometrics;

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  late final PinManager _pin = widget.pinManager ?? PinManager();
  late final BiometricManager _biometrics =
      widget.biometrics ?? BiometricManager();
  bool _hasPin = false;
  bool _biometricsAvailable = false;
  bool _biometricEnabled = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final has = await _pin.hasPin();
    final available = await _biometrics.isAvailable();
    final enabled = has && available ? await _pin.hasBiometricUnlock() : false;
    if (!mounted) return;
    setState(() {
      _hasPin = has;
      _biometricsAvailable = available;
      _biometricEnabled = enabled;
      _checking = false;
    });
  }

  Future<void> _onPinToggle(bool enabled) async {
    if (enabled) {
      final created = await _showPinDialog(setup: true);
      if (created == true) {
        // A newly created PIN starts with biometrics off; enabling it needs a
        // fresh successful device check.
        await _pin.setBiometricUnlock(false);
        if (!mounted) return;
        setState(() {
          _hasPin = true;
          _biometricEnabled = false;
        });
      }
    } else {
      final removed = await _showPinDialog(setup: false);
      if (removed == true) {
        if (!mounted) return;
        setState(() {
          _hasPin = false;
          _biometricEnabled = false;
        });
      }
    }
  }

  Future<void> _onBiometricToggle(bool enabled) async {
    if (enabled) {
      if (!_hasPin || !_biometricsAvailable) return;
      final ok = await _biometrics.authenticate(
        localizedReason: 'Confirm your fingerprint or face to enable unlock',
      );
      if (!mounted) return;
      if (!ok) {
        _showMessage(
          'Biometric check did not succeed. Try again with your device '
          'biometrics, or keep using the PIN.',
        );
        return;
      }
      await _pin.setBiometricUnlock(true);
      if (!mounted) return;
      setState(() => _biometricEnabled = true);
      _showMessage('Biometric unlock is on. Your PIN still works as fallback.');
    } else {
      await _pin.setBiometricUnlock(false);
      if (!mounted) return;
      setState(() => _biometricEnabled = false);
      _showMessage('Biometric unlock is off.');
    }
  }

  Future<void> _testBiometrics() async {
    final ok = await _biometrics.authenticate(
      localizedReason: 'Confirm your fingerprint or face',
    );
    if (!mounted) return;
    _showMessage(
      ok
          ? 'Biometric check passed on this device.'
          : 'Biometric check did not pass. Check that a fingerprint or face '
              'is enrolled in the device settings.',
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _lockNow() {
    // Pop back to the signed-in shell first, then ask it to hide its content
    // and run the biometric/PIN gate. The session is not ended.
    Navigator.of(context).popUntil((route) => route.isFirst);
    Future<void>.microtask(() {
      if (!mounted) return;
      ref.read(appLockProvider.notifier).lock();
    });
  }

  Future<void> _switchAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ref.tr('account.switch_confirm')),
        content: Text(ref.tr('account.switch_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(ref.tr('common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(ref.tr('common.continue')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // A different phone must not inherit the previous account's local lock.
    try {
      await _pin.clear();
    } catch (_) {
      // The session still ends even if the local lock cannot be cleared.
    }
    await ref.read(authProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.splash,
      (route) => false,
    );
  }

  /// Setup: enter + confirm a new PIN. Turn-off: verify current PIN.
  Future<bool?> _showPinDialog({required bool setup}) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        final confirmController = TextEditingController();
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title:
                  Text(setup ? 'Set app lock PIN' : 'Confirm PIN to turn off'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: setup ? 'New PIN (4–6 digits)' : 'Current PIN',
                      errorText: error,
                    ),
                  ),
                  if (setup) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration:
                          const InputDecoration(labelText: 'Repeat PIN'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    final pin = controller.text;
                    if (setup) {
                      if (pin.length < 4) {
                        setDialogState(() => error = 'Use at least 4 digits');
                        return;
                      }
                      if (pin != confirmController.text) {
                        setDialogState(() => error = 'PINs do not match');
                        return;
                      }
                      final ok = await _pin.setPin(pin);
                      if (ok && context.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    } else {
                      final ok = await _pin.verify(pin);
                      if (!ok) {
                        setDialogState(() => error = 'Wrong PIN');
                        return;
                      }
                      await _pin.clear();
                      if (context.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    }
                  },
                  child: Text(setup ? 'Set PIN' : 'Turn off'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.primary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                // --- App lock -------------------------------------------------
                _SectionCard(
                  title: 'App lock',
                  children: [
                    _SwitchRow(
                      label: 'PIN lock',
                      subtitle: _checking
                          ? 'Checking…'
                          : (_hasPin ? 'On — asked when the app opens' : 'Off'),
                      value: _hasPin && !_checking,
                      enabled: !_checking,
                      onChanged: _onPinToggle,
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    _SwitchRow(
                      label: 'Biometric unlock',
                      subtitle: _checking
                          ? 'Checking…'
                          : !_biometricsAvailable
                              ? 'Not available or no biometric is enrolled on this device'
                              : !_hasPin
                                  ? 'Set a PIN first'
                                  : (_biometricEnabled
                                      ? 'On — fingerprint or face is offered first'
                                      : 'Off — PIN is used'),
                      value: _biometricEnabled &&
                          _hasPin &&
                          _biometricsAvailable &&
                          !_checking,
                      enabled: !_checking && _hasPin && _biometricsAvailable,
                      onChanged: _onBiometricToggle,
                    ),
                    if (_biometricsAvailable && _hasPin)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _testBiometrics,
                            icon: const Icon(Icons.fingerprint, size: 18),
                            label: const Text('Test biometrics now'),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        _biometricsAvailable
                            ? 'When enabled, the device asks for your '
                                'fingerprint or face when the app opens. If '
                                'it fails or you cancel, the PIN dialog is '
                                'shown.'
                            : 'This device reports no enrolled fingerprint or '
                                'face. Add one in the device settings, then '
                                'reopen this screen. The PIN remains the '
                                'fallback.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_hasPin)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _lockNow,
                            icon: const Icon(Icons.lock_outline, size: 18),
                            label: const Text('Lock app now'),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // --- Session --------------------------------------------------
                _SectionCard(
                  title: 'Session',
                  children: [
                    const _InfoRow(
                      icon: Icons.schedule,
                      label: 'Stay signed in',
                      trailing: 'On this device',
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    const _InfoRow(
                      icon: Icons.language,
                      label: 'Remembered language',
                      trailing: 'This device',
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _switchAccount,
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: Text(ref.tr('account.switch')),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // --- Privacy note ---------------------------------------------
                _SectionCard(
                  title: 'Your safety',
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        'Your PIN never leaves this device and is never '
                        'sent to CrossPay. We only store an unreadable '
                        'fingerprint of it, so nobody — not even us — '
                        'can read your PIN.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Signing out ends the saved session and revokes it on the '
                    'server, so the next sign-in needs a new code. Use Lock '
                    'app now above to keep the session and unlock with '
                    'biometrics or your PIN.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                    onPressed: () async {
                      try {
                        await _pin.clear();
                      } catch (_) {
                        // The session still ends if the local lock cannot be cleared.
                      }
                      await ref.read(authProvider.notifier).signOut();
                      if (!context.mounted) return;
                      Navigator.of(context).pushNamedAndRemoveUntil(
                        AppRoutes.splash,
                        (route) => false,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeColor: AppColors.emerald,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.trailing,
  });

  final IconData icon;
  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
          Text(
            trailing,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
