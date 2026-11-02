import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// The expandable fee summary for the selected route. The fee lines are
/// exactly the ones the server lists.
class FeeBreakdownCard extends ConsumerWidget {
  const FeeBreakdownCard({super.key, required this.quote, required this.option});

  final Quote quote;
  final RouteQuote option;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final send = quote.sendCurrency;
    final receive = quote.receiveCurrency;

    Widget line(String left, String right, {bool bold = false}) {
      final style = bold
          ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)
          : theme.textTheme.bodyMedium;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(left, style: style)),
            Text(right, style: style),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text(
            ref.tr('route.breakdown_title').toUpperCase(),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ref.tr('corridor.rate_line', params: {
                'to': receive.code,
                'rate': MoneyFormat.rate(quote.rate),
                'from': send.code,
              }),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final fee in option.breakdown)
              line(
                ref.trMaybe('route.fee.${fee.code}') ?? ref.tr('route.fee.other'),
                '${MoneyFormat.format(fee.amountMinor, send.decimals)} ${send.code}',
              ),
            const Divider(),
            line(
              ref.tr('route.total_you_pay'),
              '${MoneyFormat.format(option.totalDebitMinor, send.decimals)} ${send.code}',
              bold: true,
            ),
          ],
        ),
      ),
    );
  }
}
