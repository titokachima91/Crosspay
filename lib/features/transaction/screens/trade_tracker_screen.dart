import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/features/transaction/widgets/verification_hash_card.dart';
import 'package:crosspay_app/features/transaction/widgets/trade_status_bar.dart';
import 'package:crosspay_app/features/transaction/widgets/trade_timeline_card.dart';
import 'package:crosspay_app/features/transaction/widgets/contact_support_button.dart';

class TradeTrackerScreen extends ConsumerStatefulWidget {
  const TradeTrackerScreen({super.key});
  @override
  ConsumerState<TradeTrackerScreen> createState() => _TradeTrackerScreenState();
}

class _TradeTrackerScreenState extends ConsumerState<TradeTrackerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map && args['tradeId'] != null) {
        ref.read(tradeProvider.notifier).loadTrade(args['tradeId']);
      }
    });
  }

  IconData _statusIcon(TradeStatus status) {
    switch (status) {
      case TradeStatus.pendingDeposit:
        return Icons.hourglass_empty;
      case TradeStatus.escrowed:
        return Icons.security;
      case TradeStatus.matching:
        return Icons.compare_arrows;
      case TradeStatus.matched:
        return Icons.check_circle_outline;
      case TradeStatus.disbursing:
        return Icons.send;
      case TradeStatus.completed:
        return Icons.check_circle;
      case TradeStatus.expired:
        return Icons.access_time;
      case TradeStatus.refunded:
        return Icons.reply;
      case TradeStatus.failed:
        return Icons.error;
      case TradeStatus.cancelled:
        return Icons.cancel;
    }
  }

  Color _statusColor(TradeStatus status) {
    switch (status) {
      case TradeStatus.completed:
        return AppColors.emerald;
      case TradeStatus.expired:
        return AppColors.danger;
      case TradeStatus.failed:
        return AppColors.danger;
      case TradeStatus.cancelled:
        return Theme.of(context).colorScheme.onSurfaceVariant;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final trade = ref.watch(tradeProvider).activeTrade;
    if (trade == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final scheme = Theme.of(context).colorScheme;
    final amountFormatted =
        MoneyFormat.format(trade.sendAmountMinor, trade.sendCurrency.decimals);
    final receiveFormatted = MoneyFormat.format(
      trade.receiveAmountMinor,
      trade.receiveCurrency.decimals,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
            ref.tr('tracker.title', params: {'reference': trade.reference})),
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.primary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () =>
                ref.read(tradeProvider.notifier).loadTrade(trade.id),
            tooltip: ref.tr('tracker.refresh_status'),
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Center(
                  child: Icon(
                    _statusIcon(trade.status),
                    size: 48,
                    color: _statusColor(trade.status),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  ref.tr(trade.status.labelKey),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  ref.tr('tracker.reference', params: {
                    'reference': trade.reference,
                  }),
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TradeStatusBar(status: trade.status),
                const SizedBox(height: 20),
                TradeTimelineCard(tradeId: trade.id),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ref.tr('tracker.you_pay'),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              amountFormatted,
                              textAlign: TextAlign.end,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ref.tr('tracker.recipient_gets'),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              receiveFormatted,
                              textAlign: TextAlign.end,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ref.tr('tracker.rate'),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              '1 ${trade.sendCurrency.code} = '
                              '${trade.rate.toStringAsFixed(2)} '
                              '${trade.receiveCurrency.code}',
                              textAlign: TextAlign.end,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ref.tr('tracker.fee'),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              MoneyFormat.format(
                                trade.feeMinor,
                                trade.sendCurrency.decimals,
                              ),
                              textAlign: TextAlign.end,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: scheme.onSurface,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (trade.verificationHash != null) ...[
                  const SizedBox(height: 24),
                  VerificationHashCard(hash: trade.verificationHash!),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _bottomActions(trade),
    );
  }

  Widget _bottomActions(Trade trade) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: trade.isTerminal
                  ? [
                      CustomButton(
                        label: ref.tr('tracker.done'),
                        onPressed: () {
                          ref.read(tradeProvider.notifier).resetTradeTracking();
                          Navigator.of(context).pushNamedAndRemoveUntil(
                            AppRoutes.home,
                            (route) => false,
                          );
                        },
                        accent: true,
                      ),
                    ]
                  : [
                      const ContactSupportButton(),
                      const SizedBox(height: 10),
                      CustomButton(
                        label: ref.tr('tracker.share_invoice'),
                        onPressed: () => Navigator.of(context).pushNamed(
                          AppRoutes.invoice,
                          arguments: {'tradeId': trade.id},
                        ),
                        accent: true,
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}
