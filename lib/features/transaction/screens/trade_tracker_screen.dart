import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/features/transaction/widgets/verification_hash_card.dart';
import 'package:crosspay_app/features/transaction/widgets/trade_status_bar.dart';

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

  String _statusLabel(TradeStatus status) {
    switch (status) {
      case TradeStatus.pendingDeposit: return 'Waiting for payment';
      case TradeStatus.escrowed: return 'Verifying payment';
      case TradeStatus.matching: return 'Finding payout route';
      case TradeStatus.matched: return 'Almost there';
      case TradeStatus.disbursing: return 'Paying out';
      case TradeStatus.completed: return 'Done';
      case TradeStatus.expired: return 'Rate expired';
      case TradeStatus.refunded: return 'Refunded';
      case TradeStatus.failed: return 'Failed';
      case TradeStatus.cancelled: return 'Cancelled';
    }
  }

  IconData _statusIcon(TradeStatus status) {
    switch (status) {
      case TradeStatus.pendingDeposit: return Icons.hourglass_empty;
      case TradeStatus.escrowed: return Icons.security;
      case TradeStatus.matching: return Icons.compare_arrows;
      case TradeStatus.matched: return Icons.check_circle_outline;
      case TradeStatus.disbursing: return Icons.send;
      case TradeStatus.completed: return Icons.check_circle;
      case TradeStatus.expired: return Icons.access_time;
      case TradeStatus.refunded: return Icons.reply;
      case TradeStatus.failed: return Icons.error;
      case TradeStatus.cancelled: return Icons.cancel;
    }
  }

  Color _statusColor(TradeStatus status) {
    switch (status) {
      case TradeStatus.completed: return AppColors.emerald;
      case TradeStatus.expired: return AppColors.danger;
      case TradeStatus.failed: return AppColors.danger;
      case TradeStatus.cancelled: return AppColors.textSecondary;
      default: return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final trade = ref.watch(tradeProvider).activeTrade;
    if (trade == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final statusLabel = _statusLabel(trade.status);
    final isTerminal = trade.isTerminal;
    final amountFormatted = MoneyFormat.format(trade.sendAmountMinor, trade.sendCurrency.decimals);
    return Scaffold(
      appBar: AppBar(
        title: Text('Trade #${trade.reference}'),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => ref.read(tradeProvider.notifier).loadTrade(trade.id),
            tooltip: 'Refresh status',
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(_statusIcon(trade.status), size: 48, color: _statusColor(trade.status)),
                  const SizedBox(height: 12),
                  Text(statusLabel, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  Text('Trade reference: ${trade.reference}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 24),
                  TradeStatusBar(status: trade.status),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('You pay', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text(amountFormatted, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        ]),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Recipient gets', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text(MoneyFormat.format(trade.receiveAmountMinor, trade.receiveCurrency.decimals), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        ]),
                        const Divider(height: 24),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Rate', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text('1 ${trade.sendCurrency.code} = ${trade.rate.toStringAsFixed(2)} ${trade.receiveCurrency.code}', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                        ]),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Fee', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text(MoneyFormat.format(trade.feeMinor, trade.sendCurrency.decimals), style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (trade.verificationHash != null)
                    VerificationHashCard(hash: trade.verificationHash!),
                  const SizedBox(height: 16),
                  if (!isTerminal)
                    Column(
                      children: [
                        CustomButton(label: 'Contact Support',
                          onPressed: () => Navigator.of(context).pushNamed(AppRoutes.home, arguments: {
                            'supportTradeId': trade.id,
                            'supportTradeReference': trade.reference,
                            'supportTradeStatus': trade.status.name,
                            'supportVerificationHash': trade.verificationHash,
                          }),
                        ),
                        const SizedBox(height: 12),
                        CustomButton(label: 'Share Invoice',
                          onPressed: () => Navigator.of(context).pushNamed(AppRoutes.invoice, arguments: {'tradeId': trade.id}),
                          accent: true,
                        ),
                      ],
                    )
                  else
                    CustomButton(label: 'Done',
                      onPressed: () {
                        ref.read(tradeProvider.notifier).resetTradeTracking();
                        Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.home, (route) => false);
                      },
                      accent: true,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
