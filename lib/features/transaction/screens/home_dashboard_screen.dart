import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/features/transaction/widgets/clearing_status_strip.dart';
import 'package:crosspay_app/features/transaction/widgets/converter_card.dart';
import 'package:crosspay_app/features/transaction/widgets/home_header.dart';
import 'package:crosspay_app/features/transaction/widgets/saved_recipients_row.dart';
import 'package:crosspay_app/providers/beneficiaries_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/profile_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';
import 'package:crosspay_app/providers/send_check_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 2.1: home dashboard and express converter (the Home tab).
class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  /// Loads everything the screen shows. Pull down to run it again.
  Future<void> _refresh() async {
    if (ref.read(appConfigProvider).status != ConfigStatus.ready) {
      await ref.read(appConfigProvider.notifier).load();
      if (!mounted) return;
    }
    if (ref.read(appConfigProvider).status != ConfigStatus.ready) return;

    _ensureDefaultCurrencies();
    await Future.wait([
      ref.read(profileProvider.notifier).load(),
      ref.read(ratesProvider.notifier).load(),
      ref.read(beneficiariesProvider.notifier).load(),
    ]);
  }

  /// First two currencies the server lists, until the person chooses.
  void _ensureDefaultCurrencies() {
    final currencies = ref.read(appConfigProvider).config.currencies;
    final quote = ref.read(quoteProvider);
    if (quote.sendCurrency == null && currencies.length >= 2) {
      final notifier = ref.read(quoteProvider.notifier);
      notifier.setSendCurrency(currencies[0]);
      notifier.setReceiveCurrency(currencies[1]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);

    final Widget content;
    if (config.status == ConfigStatus.ready) {
      content = Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                children: [
                  HomeHeader(onRetry: _refresh),
                  const SizedBox(height: 12),
                  const ClearingStatusStrip(),
                  const SizedBox(height: 16),
                  const ConverterCard(),
                  const SizedBox(height: 20),
                  SavedRecipientsRow(onRetry: _refresh),
                ],
              ),
            ),
          ),
          const _ReviewButton(),
        ],
      );
    } else if (config.status == ConfigStatus.error) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ref.tr(config.errorKey ?? 'error.unknown'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(ref.tr('common.retry')),
              ),
            ],
          ),
        ),
      );
    } else {
      content = const Center(child: CircularProgressIndicator());
    }

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: content,
        ),
      ),
    );
  }
}

class _ReviewButton extends ConsumerWidget {
  const _ReviewButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(sendCheckProvider);
    final quote = ref.watch(quoteProvider);
    final send = quote.sendCurrency;

    final label = (send != null && quote.sendAmountMinor > 0)
        ? ref.tr('home.review_amount', params: {
            'amount': MoneyFormat.format(quote.sendAmountMinor, send.decimals),
            'currency': send.code,
          })
        : ref.tr('home.review');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: CustomButton(
        label: label,
        onPressed: check.canReview
            ? () => Navigator.of(context).pushNamed(AppRoutes.review)
            : null,
      ),
    );
  }
}
