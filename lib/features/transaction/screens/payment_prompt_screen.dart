import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/payment_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 2.4: the payment request on the person's phone, with a manual
/// fallback. The screen only shows what the server reports: whether the
/// deposit arrived is decided by the server, never by this screen.
class PaymentPromptScreen extends ConsumerStatefulWidget {
  const PaymentPromptScreen({super.key});

  @override
  ConsumerState<PaymentPromptScreen> createState() =>
      _PaymentPromptScreenState();
}

class _PaymentPromptScreenState extends ConsumerState<PaymentPromptScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(paymentProvider.notifier).start();
    });
  }

  bool _isActive(PaymentStatus status) =>
      status == PaymentStatus.starting || status == PaymentStatus.waiting;

  void _goHome() {
    ref.read(tradeProvider.notifier).reset();
    ref.read(paymentProvider.notifier).reset();
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.home,
      (route) => false,
    );
  }

  Future<void> _confirmCancel() async {
    // Dialog text is read once here (not watched) because it is built later.
    final l10n = ref.read(localizationProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('collect.cancel_title')),
        content: Text(l10n.t('collect.cancel_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.t('collect.keep_waiting')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.t('collect.cancel')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ended = await ref.read(paymentProvider.notifier).cancel();
    if (!mounted) return;
    if (ended) _goHome();
  }

  Widget _centered(List<Widget> children) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _starting() {
    return _centered([
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text(
        ref.tr('collect.preparing'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ]);
  }

  Widget _failedToStart(PaymentState state) {
    return _centered([
      Text(
        ref.trError(key: state.errorKey ?? 'error.unknown', code: state.errorCode),
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.danger),
      ),
      const SizedBox(height: 16),
      CustomButton(
        label: ref.tr('common.retry'),
        onPressed: () => ref.read(paymentProvider.notifier).start(),
      ),
    ]);
  }

  Widget _notCompleted(PaymentState state) {
    return _centered([
      const Icon(Icons.error_outline, size: 56, color: AppColors.danger),
      const SizedBox(height: 16),
      Text(
        ref.tr('collect.not_completed', params: {
          'reference': state.trade?.reference ?? '',
        }),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 24),
      CustomButton(label: ref.tr('collect.back_home'), onPressed: _goHome),
    ]);
  }

  Widget _manualLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          SelectableText(
            value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackCard(PaymentState state, CollectionInstructions collection) {
    final theme = Theme.of(context);
    final manual = collection.manual;
    final amount =
        '${MoneyFormat.format(collection.amountMinor, collection.currency.decimals)} '
        '${collection.currency.code}';

    final String numberLabel = manual == null
        ? ''
        : (ref.trMaybe('collect.manual.${manual.methodCode}') ??
            ref.tr('collect.manual.number'));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => ref.read(paymentProvider.notifier).toggleFallback(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    state.fallbackOpen ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.navy,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ref.tr('collect.fallback_title').toUpperCase(),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (state.fallbackOpen) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ref.tr('collect.fallback_intro'),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  if (manual != null) ...[
                    _manualLine(numberLabel, manual.number),
                    _manualLine(ref.tr('collect.manual.reference'), manual.reference),
                  ],
                  _manualLine(ref.tr('collect.manual.amount'), amount),
                  const SizedBox(height: 12),
                  CustomButton(
                    label: ref.tr('collect.manual_done'),
                    onPressed: state.claimSent
                        ? null
                        : () => ref
                            .read(paymentProvider.notifier)
                            .claimManualPayment(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _waiting(PaymentState state) {
    final collection = state.collection;
    if (collection == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final amount =
        MoneyFormat.format(collection.amountMinor, collection.currency.decimals);
    final network =
        collection.networkName ?? ref.tr('collect.network_default');

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        const Icon(Icons.phone_android, size: 64, color: AppColors.navy),
        const SizedBox(height: 16),
        if (collection.pushSent) ...[
          Text(
            ref.tr('collect.push_sent'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            ref.tr('collect.instruction', params: {
              'network': network,
              'amount': amount,
              'currency': collection.currency.code,
            }),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ] else
          Text(
            ref.tr('collect.no_push'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                ref.tr(state.claimSent ? 'collect.checking' : 'collect.listening'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        if (state.pollErrorKey != null) ...[
          const SizedBox(height: 8),
          Text(
            ref.tr('collect.connection_trouble'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (state.actionErrorKey != null) ...[
          const SizedBox(height: 8),
          Text(
            ref.trError(
              key: state.actionErrorKey!,
              code: state.actionErrorCode,
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.danger),
          ),
        ],
        const SizedBox(height: 24),
        _fallbackCard(state, collection),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PaymentState>(paymentProvider, (previous, next) {
      if (next.status == PaymentStatus.paid &&
          previous?.status != PaymentStatus.paid) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.tracker,
          ModalRoute.withName(AppRoutes.home),
        );
      }
    });

    final state = ref.watch(paymentProvider);
    final active = _isActive(state.status);

    final Widget body;
    switch (state.status) {
      case PaymentStatus.idle:
      case PaymentStatus.starting:
      case PaymentStatus.paid:
        body = _starting();
      case PaymentStatus.error:
        body = _failedToStart(state);
      case PaymentStatus.notCompleted:
        body = _notCompleted(state);
      case PaymentStatus.waiting:
        body = _waiting(state);
    }

    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmCancel();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.navy,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
          automaticallyImplyLeading: false,
          leadingWidth: active ? 220 : null,
          leading: active
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _confirmCancel,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: Text(ref.tr('collect.cancel')),
                  ),
                )
              : const BackButton(),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
