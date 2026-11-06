import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Support trigger that pre-fills the trade reference.
class ContactSupportButton extends ConsumerWidget {
  const ContactSupportButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trade = ref.watch(tradeProvider).activeTrade;
    final l10n = ref.read(localizationProvider);

    return CustomButton(
      label: l10n.t('tracker.contact_support'),
      onPressed: trade == null ? null : () {
        Navigator.of(context).pushNamed(
          AppRoutes.home,
          arguments: {
            'supportTradeId': trade.id,
            'supportTradeReference': trade.reference,
            'supportTradeStatus': trade.status.name,
            'supportVerificationHash': trade.verificationHash,
          },
        );
      },
      accent: false,
    );
  }
}