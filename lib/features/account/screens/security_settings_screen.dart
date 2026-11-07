import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/security/biometric_manager.dart';
import 'package:crosspay_app/core/security/pin_manager.dart';

/// F5.3 Security settings — app-lock PIN, biometric status, sign out.
///
/// The PIN is hashed locally (never stored raw, never sent anywhere).
/// Biometric unlock is shown as plainly unavailable until the
/// local_auth package is wired per platform (product rule 5).
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  State<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final PinManager _pin = PinManager();
  bool _hasPin = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final has = await _pin.hasPin();
    if (!mounted) return;
    setState(() {
      _hasPin = has;
      _checking = false;
    });
  }

  Future<void> _onPinToggle(bool enabled) async {
    if (enabled) {
      final created = await _showPinDialog(setup: true);
      if (created == true) setState(() => _hasPin = true);
    } else {
      final removed = await _showPinDialog(setup: false);
      if (removed == true) setState(() => _hasPin = false);
    }
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
              title: Text(setup ? 'Set app lock PIN' : 'Confirm PIN to turn off'),
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
        foregroundColor: AppColors.navy,
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
                          : (_hasPin
                              ? 'On — asked when the app opens'
                              : 'Off'),
                      value: _hasPin && !_checking,
                      enabled: !_checking,
                      onChanged: _onPinToggle,
                    ),
                    const Divider(height: 1, color: AppColors.border),
                    const _InfoRow(
                      icon: Icons.lock_outline,
                      label: 'Biometric unlock',
                      trailing: 'Not available yet',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // --- Session --------------------------------------------------
                const _SectionCard(
                  title: 'Session',
                  children: [
                    _InfoRow(
                      icon: Icons.schedule,
                      label: 'Stay signed in',
                      trailing: 'Server decides',
                    ),
                    Divider(height: 1, color: AppColors.border),
                    _InfoRow(
                      icon: Icons.language,
                      label: 'Remembered language',
                      trailing: 'This device',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // --- Privacy note ---------------------------------------------
                const _SectionCard(
                  title: 'Your safety',
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        'Your PIN never leaves this device and is never '
                        'sent to CrossPay. We only store an unreadable '
                        'fingerprint of it, so nobody — not even us — '
                        'can read your PIN.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
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
                      // Session teardown handled by auth provider.
                      Navigator.of(context).popUntil((r) => r.isFirst);
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
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
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
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Text(
            trailing,
            style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}