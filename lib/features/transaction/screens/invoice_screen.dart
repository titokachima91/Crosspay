import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/features/transaction/widgets/invoice_qr_code.dart';

class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key});
  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  String? _tradeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    if (!mounted) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    final tradeId = args is Map ? args['tradeId'] as String? : null;
    if (tradeId == null) return;
    _tradeId = tradeId;
    final notifier = ref.read(tradeProvider.notifier);
    if (ref.read(tradeProvider).activeTrade?.id != tradeId) {
      await notifier.loadTrade(tradeId);
    }
    if (!mounted) return;
    await notifier.loadInvoice(tradeId);
  }

  Future<void> _copyLink(Invoice invoice) async {
    await Clipboard.setData(ClipboardData(text: invoice.shareUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ref.read(localizationProvider).t('invoice.link_copied')),
      ),
    );
  }

  void _retry() {
    final tradeId = _tradeId;
    if (tradeId != null) {
      ref.read(tradeProvider.notifier).loadInvoice(tradeId);
    }
  }

  void _done() {
    ref.read(tradeProvider.notifier).resetTradeTracking();
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.home,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tradeProvider);
    final trade = state.activeTrade;
    if (trade == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
            ref.tr('invoice.title', params: {'reference': trade.reference})),
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.primary,
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
              child: _body(trade, state),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(Trade trade, TradeState state) {
    final scheme = Theme.of(context).colorScheme;
    final errorKey = state.invoiceErrorKey;
    if (errorKey != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 48, color: scheme.error),
          const SizedBox(height: 16),
          Text(
            ref.tr(errorKey),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          CustomButton(
              label: ref.tr('invoice.retry'), onPressed: _retry, accent: true),
          const SizedBox(height: 12),
          CustomButton(label: ref.tr('tracker.done'), onPressed: _done),
        ],
      );
    }

    final invoice = state.invoice;
    if (invoice == null || state.invoiceLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final config = ref.watch(appConfigProvider).config;
    final currency =
        config.currencyByCode(invoice.currency) ?? trade.sendCurrency;
    final amount = MoneyFormat.format(invoice.amountMinor, currency.decimals);
    final localizations = MaterialLocalizations.of(context);
    final validUntil =
        localizations.formatMediumDate(invoice.validUntil.toLocal());
    final validUntilTime = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(invoice.validUntil.toLocal()),
    );

    return SingleChildScrollView(
      child: Column(
        children: [
          Icon(Icons.receipt_long, size: 48, color: scheme.primary),
          const SizedBox(height: 16),
          Text(
            ref.tr('invoice.heading'),
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            ref.tr('invoice.subtitle'),
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              children: [
                _row(ref.tr('invoice.reference'), trade.reference),
                const SizedBox(height: 12),
                _row(
                  ref.tr('invoice.amount'),
                  '$amount ${invoice.currency}',
                  emphasise: true,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      ref.tr('invoice.status'),
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.emerald.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          ref.tr(trade.status.labelKey),
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.emerald,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _row(
                  ref.tr('invoice.valid_until'),
                  '$validUntil $validUntilTime',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          InvoiceQrCode(
            qrCodeUrl: invoice.qrCodeUrl,
            reference: trade.reference,
          ),
          const SizedBox(height: 24),
          CustomButton(
            label: ref.tr('invoice.copy_link'),
            onPressed: () => _copyLink(invoice),
            accent: true,
          ),
          const SizedBox(height: 12),
          CustomButton(label: ref.tr('tracker.done'), onPressed: _done),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool emphasise = false}) {
    final scheme = Theme.of(context).colorScheme;
    final style = emphasise
        ? Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface)
        : Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Flexible(
          child: Text(value, textAlign: TextAlign.right, style: style),
        ),
      ],
    );
  }
}
