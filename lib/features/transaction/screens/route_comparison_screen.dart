import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/quote_provider.dart';

/// Advanced Payment Routing — route comparison screen.
///
/// Kept extra: this screen is outside the F1-F5 plan (see the "Kept extras"
/// section of MASTER_PROGRESS_REPORT.md).
///
/// Shows every route the server priced for the current quote (You pay /
/// Recipient gets / fee lines / arrival estimate) and lets the user pick
/// one. Nothing is calculated client-side: every figure comes from the
/// server's quote response. Returns the selected [RouteType] via
/// Navigator.pop when the user confirms.
class RouteComparisonScreen extends ConsumerStatefulWidget {
  const RouteComparisonScreen({super.key});

  @override
  ConsumerState<RouteComparisonScreen> createState() =>
      _RouteComparisonScreenState();
}

class _RouteComparisonScreenState
    extends ConsumerState<RouteComparisonScreen> {
  RouteType? _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final quote = ref.read(quoteProvider).quote;
      if (quote != null) {
        _selected = quote.defaultRoute?.route;
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(quoteProvider).quote;
    final routes = quote?.routes ?? const <RouteQuote>[];
    final sendDecimals = quote?.sendCurrency.decimals ?? 2;
    final receiveDecimals = quote?.receiveCurrency.decimals ?? 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compare routes'),
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
            child: routes.isEmpty
                ? const _EmptyState()
                : ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: routes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final route = routes[index];
                      return _RouteCard(
                        route: route,
                        selected: route.route == _selected,
                        sendDecimals: sendDecimals,
                        receiveDecimals: receiveDecimals,
                        onTap: route.isAvailable
                            ? () => setState(() => _selected = route.route)
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ),
      bottomNavigationBar: routes.isEmpty || _selected == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.emerald,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text(
                      'Use this route',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.route,
    required this.selected,
    required this.sendDecimals,
    required this.receiveDecimals,
    required this.onTap,
  });

  final RouteQuote route;
  final bool selected;
  final int sendDecimals;
  final int receiveDecimals;
  final VoidCallback? onTap;

  String get _routeLabel =>
      route.route == RouteType.p2p ? 'Instant (P2P)' : 'Bank transfer';

  String _etaLabel() {
    final min = route.estimatedMinSeconds;
    final max = route.estimatedMaxSeconds;
    if (max < 60) return 'Under a minute';
    if (max < 3600) {
      return min == max ? '~${max ~/ 60} min' : '${min ~/ 60}–${max ~/ 60} min';
    }
    return '~${max ~/ 3600} h';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.emerald.withOpacity(0.08)
          : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? AppColors.emerald : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color:
                        selected ? AppColors.emerald : AppColors.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _routeLabel,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.navy,
                      ),
                    ),
                  ),
                  if (route.isRecommended)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.emerald.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Recommended',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.emerald,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _KeyValueRow(
                label: 'You pay',
                value: MoneyFormat.format(
                    route.totalDebitMinor, sendDecimals),
              ),
              _KeyValueRow(
                label: 'Recipient gets',
                value: MoneyFormat.format(route.payoutMinor, receiveDecimals),
              ),
              _KeyValueRow(
                label: 'Fee',
                value: MoneyFormat.format(route.feeMinor, sendDecimals),
              ),
              _KeyValueRow(
                label: 'Estimated arrival',
                value: _etaLabel(),
              ),
              if (!route.isAvailable)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Unavailable',
                    style: TextStyle(fontSize: 13, color: AppColors.danger),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
                fontSize: 14, color: AppColors.textSecondary),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.navy,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No routes available yet.\nPlease go back and request a quote.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}