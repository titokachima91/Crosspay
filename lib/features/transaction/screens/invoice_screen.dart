import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/features/transaction/widgets/invoice_qr_code.dart';

class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key});
  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map && args['tradeId'] != null) {
        ref.read(tradeProvider.notifier).loadTrade(args['tradeId']);
        ref.read(tradeProvider.notifier).shareInvoice();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final trade = ref.watch(tradeProvider).activeTrade;
    if (trade == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final amountFormatted = MoneyFormat.format(trade.sendAmountMinor, trade.sendCurrency.decimals);
    return Scaffold(
      appBar: AppBar(
        title: Text('Invoice #${trade.reference}'),
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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.receipt_long, size: 48, color: AppColors.navy),
                  const SizedBox(height: 16),
                  Text('Digital Invoice', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text('Share this invoice so the recipient can pay', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                    child: Column(
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Trade reference', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text(trade.reference, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Amount', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Text(amountFormatted, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        ]),
                        const SizedBox(height: 12),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text('Status', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: AppColors.emerald.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                            child: Text('Pending', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.emerald)),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  InvoiceQrCode(tradeId: trade.id, reference: trade.reference, amount: trade.sendAmountMinor, currency: trade.sendCurrency.code),
                  const SizedBox(height: 24),
                  CustomButton(label: 'Share Invoice',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invoice shared via system share sheet'), duration: Duration(seconds: 2)));
                    },
                    accent: true,
                  ),
                  const SizedBox(height: 12),
                  CustomButton(label: 'Done',
                    onPressed: () {
                      ref.read(tradeProvider.notifier).resetTradeTracking();
                      Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.home, (route) => false);
                    },
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