import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/features/support/models/support_trade_context.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Support trigger that carries the trade reference, status and hash into the
/// support screen. No personal data is attached.
class ContactSupportButton extends ConsumerWidget {
  const ContactSupportButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trade = ref.watch(tradeProvider).activeTrade;

    return CustomButton(
      label: ref.tr('tracker.contact_support'),
      onPressed: trade == null
          ? null
          : () {
              Navigator.of(context).pushNamed(
                AppRoutes.support,
                arguments: SupportTradeContext(
                  tradeId: trade.id,
                  reference: trade.reference,
                  status: trade.status,
                  verificationHash: trade.verificationHash,
                ),
              );
            },
      accent: false,
    );
  }
}
