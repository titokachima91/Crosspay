import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/analytics_model.dart';
import 'package:crosspay_app/providers/analytics_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F4.1 — spending analytics, aggregated by the server
/// (`GET /trades/analytics`). The app adds nothing up on the device; while the
/// endpoint does not exist the screen says so plainly.
class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(analyticsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(analyticsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('analytics.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: ref.tr('common.retry'),
            onPressed: () => ref.read(analyticsProvider.notifier).load(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _body(state),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AnalyticsState state) {
    if (state.status == AnalyticsStatus.loading && state.analytics == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == AnalyticsStatus.unavailable) {
      return Center(
        child: Text(
          ref.tr('analytics.unavailable'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }
    if (state.status == AnalyticsStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref.tr(state.errorKey ?? 'error.unknown'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => ref.read(analyticsProvider.notifier).load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        ),
      );
    }

    final analytics = state.analytics;
    if (analytics == null || analytics.trades == 0) {
      return Center(
        child: Text(
          ref.tr('analytics.none'),
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }

    return ListView(
      children: [
        _TotalsCard(analytics: analytics),
        const SizedBox(height: 20),
        Text(
          ref.tr('analytics.by_corridor').toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 8),
        for (final corridor in analytics.corridors)
          _CorridorRow(spend: corridor),
      ],
    );
  }
}

class _TotalsCard extends ConsumerWidget {
  const _TotalsCard({required this.analytics});

  final TradeAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sent = MoneyFormat.format(
      analytics.sentMinor,
      analytics.sentCurrency.decimals,
    );
    final received = MoneyFormat.format(
      analytics.receivedMinor,
      analytics.receivedCurrency.decimals,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.navy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tr('analytics.trades'),
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          Text(
            '${analytics.trades}',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          _line(
            ref.tr('analytics.total_sent'),
            '${analytics.sentCurrency.code} $sent',
          ),
          const SizedBox(height: 6),
          _line(
            ref.tr('analytics.total_received'),
            '${analytics.receivedCurrency.code} $received',
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      );
}

class _CorridorRow extends ConsumerWidget {
  const _CorridorRow({required this.spend});

  final CorridorSpend spend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount = MoneyFormat.format(spend.sentMinor, spend.from.decimals);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${spend.from.code} → ${spend.to.code}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  ref.tr('analytics.corridor_line', params: {
                    'trades': '${spend.trades}',
                    'amount': '${spend.from.code} $amount',
                  }),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${spend.from.code} $amount',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}