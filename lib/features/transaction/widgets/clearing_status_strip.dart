import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';

/// "Regional clearing active | Tanzania ⇄ Kenya", built from the live rates.
/// Says so plainly when that information is not available.
class ClearingStatusStrip extends ConsumerWidget {
  const ClearingStatusStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(ratesProvider);
    final countries = ref.watch(appConfigProvider).config.countries;

    final String text;
    Color dot = AppColors.border;

    if (rates.status == RatesStatus.error ||
        (rates.status == RatesStatus.live && rates.rates.isEmpty)) {
      text = ref.tr('home.clearing_unavailable');
    } else if (rates.rates.isEmpty) {
      return const SizedBox.shrink(); // not loaded yet
    } else {
      CorridorLevel? worst;
      for (final r in rates.rates) {
        final level = r.status?.level;
        if (level == null) continue;
        if (worst == null || level.index > worst.index) worst = level;
      }

      final names = <String>[];
      for (final r in rates.rates) {
        for (final currency in [r.from, r.to]) {
          var name = currency.countryCode;
          for (final c in countries) {
            if (c.code == currency.countryCode) name = c.name;
          }
          if (!names.contains(name)) names.add(name);
        }
      }

      final label = worst == null
          ? ref.tr('home.clearing.unknown')
          : ref.tr('home.clearing.${worst.name}');
      dot = switch (worst) {
        CorridorLevel.healthy => AppColors.success,
        CorridorLevel.limited => AppColors.warning,
        CorridorLevel.down => AppColors.danger,
        null => AppColors.border,
      };
      text = '$label  |  ${names.join('  \u21C4  ')}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
