import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
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
      body: IndexedStack(
        index: _index,
        children: const [
          HomeDashboardScreen(),
          _PlaceholderTab(label: 'Next: F4.1 ledger'),
          _PlaceholderTab(label: 'Next: F4.2 rates'),
          _PlaceholderTab(label: 'Next: F5.1 account'),
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
