import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// The global 4-tab bar: Home, Ledger, Rates, Account.
class PersistentBottomNav extends ConsumerWidget {
  const PersistentBottomNav({
    super.key,
    required this.currentIndex,
    required this.onSelected,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onSelected,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: ref.tr('nav.home'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.receipt_long_outlined),
          selectedIcon: const Icon(Icons.receipt_long),
          label: ref.tr('nav.ledger'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.show_chart),
          selectedIcon: const Icon(Icons.show_chart),
          label: ref.tr('nav.rates'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: ref.tr('nav.account'),
        ),
      ],
    );
  }
}
