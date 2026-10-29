import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';

/// "Live regional corridor health" card (Screen 1.1). Shows only what the
/// server sent, or says plainly why there is nothing to show.
class CorridorHealthCard extends ConsumerWidget {
  const CorridorHealthCard({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    final rates = ref.watch(ratesProvider);

    final Widget body;
    if (config.status == ConfigStatus.error) {
      body = _MessageWithRetry(
        text: ref.tr(config.errorKey ?? 'error.unknown'),
        onRetry: onRetry,
      );
    } else if (rates.status == RatesStatus.error) {
      body = _MessageWithRetry(
        text: ref.tr(rates.errorKey ?? 'error.unknown'),
        onRetry: onRetry,
      );
    } else if (rates.rates.isNotEmpty) {
      body = Column(
        children: [
          for (final r in _firstPerPair(rates.rates)) _RateRow(rate: r),
        ],
      );
    } else if (rates.status == RatesStatus.live ||
        (config.status == ConfigStatus.ready && config.config.isEmpty)) {
      body = Text(
        ref.tr('corridor.empty'),
        style: Theme.of(context).textTheme.bodyMedium,
      );
    } else {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sensors, color: AppColors.emerald, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ref.tr('corridor.title').toUpperCase(),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }
}

/// The server decides the order. Show each pair once, in its first direction.
List<CorridorRate> _firstPerPair(List<CorridorRate> rates) {
  final seen = <String>{};
  final result = <CorridorRate>[];
  for (final r in rates) {
    final pair = [r.from.code, r.to.code]..sort();
    if (seen.add(pair.join('-'))) result.add(r);
  }
  return result;
}

String _formatRate(double rate) =>
    rate >= 1 ? rate.toStringAsFixed(2) : rate.toStringAsFixed(4);

class _MessageWithRetry extends ConsumerWidget {
  const _MessageWithRetry({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(ref.tr('common.retry')),
        ),
      ],
    );
  }
}

class _RateRow extends ConsumerWidget {
  const _RateRow({required this.rate});

  final CorridorRate rate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = rate.status;
    final dotColor = switch (status?.level) {
      CorridorLevel.healthy => AppColors.success,
      CorridorLevel.limited => AppColors.warning,
      CorridorLevel.down => AppColors.danger,
      null => AppColors.border,
    };

    String? statusLabel;
    if (status != null) {
      statusLabel = ref.trMaybe('corridor.status.${status.code}') ??
          ref.tr('corridor.level.${status.level.name}');
    }

    final pair = '${countryFlag(rate.from.countryCode)} ${rate.from.code}'
        '  \u21C4  '
        '${countryFlag(rate.to.countryCode)} ${rate.to.code}';

    final rateLine = ref.tr('corridor.rate_line', params: {
      'to': rate.to.code,
      'rate': _formatRate(rate.rate),
      'from': rate.from.code,
    });

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  pair,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              if (statusLabel != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    statusLabel,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(rateLine, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
