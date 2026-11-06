import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/security/pin_manager.dart';
import 'package:crosspay_app/features/account/screens/account_tab_screen.dart';
import 'package:crosspay_app/features/transaction/screens/home_dashboard_screen.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/widgets/persistent_bottom_nav.dart';

/// The signed-in app: four tabs under one navigation bar.
class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  int _index = 0;
  bool _gated = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _gate());
  }

  /// F5.3 — app-lock gate. Runs once per shell mount: when a PIN is
  /// set the person must enter it before the tabs become usable.
  /// Cancel pops back to the previous screen (never traps in a loop).
  Future<void> _gate() async {
    if (_gated) return;
    _gated = true;
    bool unlocked;
    try {
      unlocked = await PinManager().ensureUnlocked(context);
    } catch (e) {
      // Secure storage unavailable (tests, broken keystore): fail
      // open so a storage error never locks the person out of their
      // own device. PIN guards app surface only; session security
      // stays with the server (refresh tokens, timeouts).
      unlocked = true;
    }
    if (!mounted) return;
    if (unlocked) {
      setState(() => _visible = true);
    } else {
      // Cancelled the PIN prompt: leave the shell.
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // If the session ends (for example the token expired), go back to the start.
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (previous?.status != AuthStatus.signedOut &&
          next.status == AuthStatus.signedOut) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.splash,
          (route) => false,
        );
      }
    });

    return Scaffold(
      body: !_visible
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.emerald))
          : IndexedStack(
              index: _index,
              children: const [
                HomeDashboardScreen(),
                _PlaceholderTab(label: 'Next: F4.1 ledger'),
                _PlaceholderTab(label: 'Next: F4.2 rates'),
                AccountTabScreen(),
              ],
            ),
      bottomNavigationBar: PersistentBottomNav(
        currentIndex: _index,
        onSelected: (index) => setState(() => _index = index),
      ),
    );
  }
}

// TEMPORARY: each tab is replaced by its real screen (F4.1, F4.2, F5.1).
class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(child: Text('$label (temporary tab)')),
    );
  }
}
