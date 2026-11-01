import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/amount_input_formatter.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/profile_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';
import 'package:crosspay_app/providers/send_check_provider.dart';

/// The express currency converter. The server supplies the currencies and
/// every figure shown on the receiving side.
class ConverterCard extends ConsumerStatefulWidget {
  const ConverterCard({super.key});

  @override
  ConsumerState<ConverterCard> createState() => _ConverterCardState();
}

class _ConverterCardState extends ConsumerState<ConverterCard> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyAmount() {
    final send = ref.read(quoteProvider).sendCurrency;
    final minor = send == null
        ? 0
        : (MoneyFormat.parse(_controller.text, send.decimals) ?? 0);
    ref.read(quoteProvider.notifier).setSendAmount(minor);
  }

  /// A different currency can allow fewer decimals: re-apply the typed text.
  void _reformatFor(Currency send) {
    final formatter = AmountInputFormatter(decimals: send.decimals);
    _controller.value =
        formatter.formatEditUpdate(_controller.value, _controller.value);
    _applyAmount();
  }

  void _onSendCurrency(Currency selected) {
    final quote = ref.read(quoteProvider);
    final notifier = ref.read(quoteProvider.notifier);
    final previousSend = quote.sendCurrency;
    if (selected == quote.receiveCurrency && previousSend != null) {
      notifier.setReceiveCurrency(previousSend);
    }
    notifier.setSendCurrency(selected);
    _reformatFor(selected);
  }

  void _onReceiveCurrency(Currency selected) {
    final quote = ref.read(quoteProvider);
    final notifier = ref.read(quoteProvider.notifier);
    final previousReceive = quote.receiveCurrency;
    if (selected == quote.sendCurrency && previousReceive != null) {
      notifier.setSendCurrency(previousReceive);
      notifier.setReceiveCurrency(selected);
      _reformatFor(previousReceive);
    } else {
      notifier.setReceiveCurrency(selected);
    }
  }

  void _swap() {
    final quote = ref.read(quoteProvider);
    final send = quote.sendCurrency;
    final receive = quote.receiveCurrency;
    if (send == null || receive == null) return;

    final notifier = ref.read(quoteProvider.notifier);
    notifier.setSendCurrency(receive);
    notifier.setReceiveCurrency(send);
    _reformatFor(receive);
  }

  String _timeText(int seconds) {
    if (seconds < 60) return ref.tr('home.time_instant');
    if (seconds < 3600) {
      return ref.tr('home.time_minutes', params: {
        'n': '${(seconds / 60).round()}',
      });
    }
    return ref.tr('home.time_hours', params: {
      'n': '${(seconds / 3600).round()}',
    });
  }

  String? _problemText(SendProblem? problem) {
    final profile = ref.watch(profileProvider).profile;
    switch (problem) {
      case null:
        return null;
      case SendProblem.verificationPending:
        return ref.tr('home.verification_pending');
      case SendProblem.verificationRequired:
        return ref.tr('home.verification_needed');
      case SendProblem.overLimit:
        if (profile == null) return null;
        return ref.tr('home.over_limit', params: {
          'amount': MoneyFormat.format(
            profile.dailyRemainingMinor,
            profile.limitCurrency.decimals,
          ),
          'currency': profile.limitCurrency.code,
        });
    }
  }

  Widget _frame(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ref.watch(appConfigProvider).config.currencies;
    final quote = ref.watch(quoteProvider);
    final estimate = ref.watch(estimateProvider);
    final check = ref.watch(sendCheckProvider);
    final rates = ref.watch(ratesProvider);
    final theme = Theme.of(context);

    if (currencies.length < 2) {
      return _frame(Text(
        ref.tr('home.no_currencies'),
        style: theme.textTheme.bodyMedium,
      ));
    }

    final send = quote.sendCurrency;
    final receive = quote.receiveCurrency;
    if (send == null || receive == null) {
      return _frame(const Center(child: CircularProgressIndicator()));
    }

    final est = estimate.estimate;
    final receiveText = (est != null && quote.sendAmountMinor > 0)
        ? MoneyFormat.format(est.receiveAmountMinor, receive.decimals)
        : '';

    final double? shownRate = est?.rate ?? rates.rateFor(send, receive)?.rate;
    final problem = _problemText(check.problem);

    return _frame(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tr('home.converter_title').toUpperCase(),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 16),
          Text(ref.tr('home.you_send'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              _CurrencyDropdown(
                currencies: currencies,
                selected: send,
                onChanged: _onSendCurrency,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _controller,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.titleLarge,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: send.decimals > 0,
                  ),
                  inputFormatters: [
                    AmountInputFormatter(decimals: send.decimals),
                  ],
                  decoration: const InputDecoration(hintText: '0'),
                  onChanged: (_) => _applyAmount(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: Divider()),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _swap,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.swap_vert,
                          size: 18, color: AppColors.navy),
                      if (shownRate != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          ref.tr('corridor.rate_line', params: {
                            'to': receive.code,
                            'rate': MoneyFormat.rate(shownRate),
                            'from': send.code,
                          }),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 12),
          Text(ref.tr('home.recipient_gets'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              _CurrencyDropdown(
                currencies: currencies,
                selected: receive,
                onChanged: _onReceiveCurrency,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 56,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Opacity(
                    opacity:
                        estimate.status == EstimateStatus.loading ? 0.45 : 1,
                    child: Text(
                      receiveText,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (est != null && quote.sendAmountMinor > 0) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                ref.tr('home.delivery', params: {
                  'time': _timeText(est.estimatedMinSeconds),
                  'route': ref.tr(
                    est.route == RouteType.p2p
                        ? 'home.route_p2p'
                        : 'home.route_bank',
                  ),
                }),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          if (estimate.status == EstimateStatus.error) ...[
            const SizedBox(height: 8),
            Text(
              ref.tr(estimate.errorKey ?? 'error.unknown'),
              style: const TextStyle(color: AppColors.danger),
            ),
          ],
          if (problem != null) ...[
            const SizedBox(height: 8),
            Text(problem, style: const TextStyle(color: AppColors.danger)),
          ],
        ],
      ),
    );
  }
}

class _CurrencyDropdown extends StatelessWidget {
  const _CurrencyDropdown({
    required this.currencies,
    required this.selected,
    required this.onChanged,
  });

  final List<Currency> currencies;
  final Currency selected;
  final ValueChanged<Currency> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Currency>(
          value: currencies.contains(selected) ? selected : null,
          items: [
            for (final c in currencies)
              DropdownMenuItem<Currency>(
                value: c,
                child: Text('${countryFlag(c.countryCode)} ${c.code}'),
              ),
          ],
          onChanged: (currency) {
            if (currency != null) onChanged(currency);
          },
        ),
      ),
    );
  }
}
