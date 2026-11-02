import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/widgets/status_badge.dart';

/// One route (P2P or bank) as priced by the server. Every figure and every
/// claim shown here comes from the quote.
class RouteOptionCard extends ConsumerWidget {
  const RouteOptionCard({
    super.key,
    required this.letter,
    required this.quote,
    required this.option,
    required this.selected,
    required this.isFastest,
    required this.onTap,
  });

  final String letter;
  final Quote quote;
  final RouteQuote option;
  final bool selected;
  final bool isFastest;
  final VoidCallback onTap;

  String _unit(WidgetRef ref, int seconds) {
    if (seconds < 60) {
      return ref.tr('route.unit_sec', params: {'n': '$seconds'});
    }
    if (seconds < 3600) {
      return ref.tr('route.unit_min', params: {'n': '${(seconds / 60).round()}'});
    }
    return ref.tr('route.unit_hour', params: {'n': '${(seconds / 3600).round()}'});
  }

  String _speedRange(WidgetRef ref) {
    if (option.estimatedMaxSeconds <= 60) return ref.tr('route.under_a_minute');
    final from = _unit(ref, option.estimatedMinSeconds);
    final to = _unit(ref, option.estimatedMaxSeconds);
    return from == to ? from : '$from \u2013 $to';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final send = quote.sendCurrency;
    final receive = quote.receiveCurrency;
    final enabled = option.isAvailable;
    final status = option.status;

    String? statusText;
    var statusColor = AppColors.textSecondary;
    if (status != null) {
      final label = ref.trMaybe('route.status.${status.code}') ??
          ref.tr('corridor.level.${status.level.name}');
      statusText = ref.tr('route.status', params: {'label': label});
      statusColor = switch (status.level) {
        CorridorLevel.healthy => AppColors.success,
        CorridorLevel.limited => AppColors.warning,
        CorridorLevel.down => AppColors.danger,
      };
    } else if (!enabled) {
      statusText = ref.tr('route.unavailable');
      statusColor = AppColors.danger;
    }

    // A safeguard claim is shown only when the server confirms it AND the app
    // has approved wording for that code.
    final safeguardCode = option.safeguardCode;
    final safeguardText = safeguardCode == null
        ? null
        : ref.trMaybe('route.safeguard.$safeguardCode');

    Widget infoRow(IconData icon, String text, {Color? color}) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color ?? AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      );
    }

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.navy : AppColors.border,
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
                        : Icons.radio_button_unchecked,
                    color: AppColors.navy,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ref.tr('route.option', params: {'letter': letter}),
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          ref.tr('route.title_${option.route.name}'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (option.isRecommended || isFastest) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (option.isRecommended)
                      StatusBadge(
                        label: ref.tr('route.badge_best_value'),
                        tone: BadgeTone.success,
                      ),
                    if (isFastest)
                      StatusBadge(
                        label: ref.tr('route.badge_fastest'),
                        tone: BadgeTone.neutral,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
              infoRow(
                Icons.speed,
                ref.tr('route.speed', params: {'range': _speedRange(ref)}),
              ),
              infoRow(
                Icons.payments_outlined,
                ref.tr('route.fee', params: {
                  'percent': MoneyFormat.percentFromBps(option.feeBps),
                  'amount': MoneyFormat.format(option.feeMinor, send.decimals),
                  'currency': send.code,
                }),
              ),
              if (safeguardText != null)
                infoRow(Icons.shield_outlined, safeguardText),
              if (statusText != null)
                infoRow(Icons.circle, statusText, color: statusColor),
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Divider(height: 1),
              ),
              const SizedBox(height: 12),
              Text(
                ref.tr('route.you_pay', params: {
                  'amount':
                      MoneyFormat.format(option.totalDebitMinor, send.decimals),
                  'currency': send.code,
                }),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                ref.tr('route.recipient_gets', params: {
                  'amount':
                      MoneyFormat.format(option.payoutMinor, receive.decimals),
                  'currency': receive.code,
                }),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
