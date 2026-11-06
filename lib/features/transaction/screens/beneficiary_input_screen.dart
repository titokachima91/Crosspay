import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/core/utils/national_number_formatter.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/features/transaction/widgets/rate_lock_pill.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/authorize_check.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/recipient_check_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/widgets/status_badge.dart';

/// Screen 2.3: who gets the money, checked with the destination network.
///
/// The destination is the country of the currency being received. The check
/// only ever says "found" and "name matches"; the registered name is never
/// shown. Authorize stays off until the check allows it.
class BeneficiaryInputScreen extends ConsumerStatefulWidget {
  const BeneficiaryInputScreen({super.key});

  @override
  ConsumerState<BeneficiaryInputScreen> createState() =>
      _BeneficiaryInputScreenState();
}

class _BeneficiaryInputScreenState
    extends ConsumerState<BeneficiaryInputScreen> {
  // The money flow has three steps by design: route, recipient, payment.
  static const int _step = 2;
  static const int _totalSteps = 3;

  final TextEditingController _accountController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _referenceController = TextEditingController();
  PayoutRail? _rail;

  @override
  void initState() {
    super.initState();
    _prefill();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(recipientCheckProvider.notifier).clear();
      _runCheck();
    });
  }

  @override
  void dispose() {
    _accountController.dispose();
    _nameController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Country? _countryFor(AppConfig config, Quote quote) {
    for (final c in config.countries) {
      if (c.code == quote.receiveCurrency.countryCode) return c;
    }
    return null;
  }

  /// First payout option of the destination, or the saved recipient's.
  void _prefill() {
    final quote = ref.read(quoteProvider).quote;
    if (quote == null) return;

    final config = ref.read(appConfigProvider).config;
    final rails = config.railsForCountry(quote.receiveCurrency.countryCode);
    if (rails.isEmpty) return;
    _rail = rails.first;

    final saved = ref.read(tradeProvider).beneficiary;
    if (saved == null || !rails.contains(saved.rail)) return;

    _rail = saved.rail;
    _nameController.text = saved.name;

    final country = _countryFor(config, quote);
    if (saved.rail.kind == PayoutKind.mobileMoney && country != null) {
      final national =
          PhoneUtils.nationalFromInternational(saved.accountOrPhone, country);
      final formatter =
          NationalNumberFormatter(maxDigits: country.nationalNumberLength);
      _accountController.text = formatter
          .formatEditUpdate(
            _accountController.value,
            _accountController.value.copyWith(text: national),
          )
          .text;
    } else {
      _accountController.text = saved.accountOrPhone;
    }
  }

  String _normalizedAccount(PayoutRail rail, Country? country) {
    final text = _accountController.text;
    if (rail.kind == PayoutKind.mobileMoney && country != null) {
      return PhoneUtils.toInternational(country, text);
    }
    return text.trim();
  }

  bool _accountReady(PayoutRail rail, Country? country) {
    final text = _accountController.text;
    if (rail.kind == PayoutKind.mobileMoney && country != null) {
      return PhoneUtils.isComplete(country, text);
    }
    return text.trim().isNotEmpty;
  }

  void _runCheck() {
    final quote = ref.read(quoteProvider).quote;
    final rail = _rail;
    if (quote == null || rail == null) return;

    final country = _countryFor(ref.read(appConfigProvider).config, quote);
    ref.read(recipientCheckProvider.notifier).inputsChanged(
          rail: rail,
          account: _normalizedAccount(rail, country),
          accountReady: _accountReady(rail, country),
          name: _nameController.text.trim(),
        );
  }

  void _selectRail(PayoutRail rail) {
    if (rail == _rail) return;
    final kindChanged = _rail?.kind != rail.kind;
    setState(() {
      _rail = rail;
      if (kindChanged) _accountController.clear();
    });
    _runCheck();
  }

  void _onFieldChanged() {
    setState(() {});
    _runCheck();
  }

  void _authorize() {
    FocusScope.of(context).unfocus();
    final quote = ref.read(quoteProvider).quote;
    final rail = _rail;
    final check = ref.read(recipientCheckProvider).check;
    if (quote == null || rail == null || check == null) return;

    final country = _countryFor(ref.read(appConfigProvider).config, quote);
    ref.read(tradeProvider.notifier).authorize(
          RecipientDetails(
            rail: rail,
            account: _normalizedAccount(rail, country),
            name: _nameController.text.trim(),
            reference: _referenceController.text.trim(),
            check: check,
          ),
          quoteId: quote.id,
        );
    Navigator.of(context).pushNamed(AppRoutes.payment);
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.navy,
            ),
      ),
    );
  }

  Widget _note(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountStatus(RecipientCheckState state) {
    switch (state.status) {
      case RecipientCheckStatus.idle:
        return const SizedBox.shrink();
      case RecipientCheckStatus.loading:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                ref.tr('recipient.checking'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        );
      case RecipientCheckStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _note(
              Icons.error_outline,
              ref.trError(
                key: state.errorKey ?? 'error.unknown',
                code: state.errorCode,
              ),
              AppColors.danger,
            ),
            TextButton.icon(
              onPressed: _runCheck,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        );
      case RecipientCheckStatus.ready:
        final check = state.check;
        if (check == null) return const SizedBox.shrink();
        if (check.accountStatus == AccountStatus.notFound) {
          return _note(
            Icons.error_outline,
            ref.tr('recipient.account_not_found'),
            AppColors.danger,
          );
        }
        final network = check.networkName;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: StatusBadge(
              label: network == null
                  ? ref.tr('recipient.account_found')
                  : ref.tr('recipient.network_confirmed',
                      params: {'network': network}),
              tone: BadgeTone.success,
            ),
          ),
        );
    }
  }

  Widget _nameStatus(RecipientCheckState state, AuthorizeCheck authorize) {
    final check = state.status == RecipientCheckStatus.ready ? state.check : null;
    if (check == null || check.accountStatus != AccountStatus.found) {
      return const SizedBox.shrink();
    }
    if (_nameController.text.trim().isEmpty) {
      return _note(
        Icons.info_outline,
        ref.tr('recipient.enter_name'),
        AppColors.textSecondary,
      );
    }
    switch (check.nameMatch) {
      case NameMatch.match:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: StatusBadge(
              label: ref.tr('recipient.name_matches'),
              tone: BadgeTone.success,
            ),
          ),
        );
      case NameMatch.mismatch:
        return _note(
          Icons.error_outline,
          ref.tr('recipient.name_mismatch'),
          AppColors.danger,
        );
      case NameMatch.unavailable:
        return _note(
          Icons.warning_amber_rounded,
          ref.tr('recipient.name_unverified'),
          AppColors.warning,
        );
      case null:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final quoteState = ref.watch(quoteProvider);
    final config = ref.watch(appConfigProvider).config;
    final checkState = ref.watch(recipientCheckProvider);
    final quote = quoteState.quote;
    final theme = Theme.of(context);

    final appBar = AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.navy,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 16),
          child: Center(child: RateLockPill()),
        ),
      ],
    );

    if (quote == null) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              ref.tr('recipient.no_quote'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    final rails = config.railsForCountry(quote.receiveCurrency.countryCode);
    final country = _countryFor(config, quote);
    final rail = rails.contains(_rail) ? _rail : null;

    final authorize = checkAuthorize(
      quote: quoteState,
      check: checkState,
      name: _nameController.text,
    );
    final selected = quoteState.selectedRoute;
    final option = selected == null ? null : quote.forRoute(selected);
    final authorizeLabel = option == null
        ? ref.tr('recipient.authorize')
        : ref.tr('recipient.authorize_amount', params: {
            'amount': MoneyFormat.format(
              option.totalDebitMinor,
              quote.sendCurrency.decimals,
            ),
            'currency': quote.sendCurrency.code,
          });

    final mobile = rail?.kind == PayoutKind.mobileMoney;

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ref.tr('kyc.step', params: {
                            'current': '$_step',
                            'total': '$_totalSteps',
                          }),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: AppColors.emerald,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          ref.tr('recipient.title'),
                          style: theme.textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 24),
                        if (rails.isEmpty)
                          Text(
                            ref.tr('recipient.no_rails'),
                            style: theme.textTheme.bodyMedium,
                          )
                        else ...[
                          _label(ref.tr('recipient.rail_label')),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final r in rails)
                                ChoiceChip(
                                  label: Text(r.name),
                                  selected: r == rail,
                                  onSelected: (_) => _selectRail(r),
                                ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _label(ref.tr(mobile
                              ? 'recipient.account_mobile'
                              : 'recipient.account_bank')),
                          if (mobile && country != null)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  height: 56,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Text(
                                    '${countryFlag(country.code)} +${country.dialCode}',
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: _accountController,
                                    keyboardType: TextInputType.phone,
                                    inputFormatters: [
                                      NationalNumberFormatter(
                                        maxDigits: country.nationalNumberLength,
                                      ),
                                    ],
                                    onChanged: (_) => _onFieldChanged(),
                                  ),
                                ),
                              ],
                            )
                          else
                            TextField(
                              controller: _accountController,
                              keyboardType: mobile
                                  ? TextInputType.phone
                                  : TextInputType.text,
                              autocorrect: false,
                              enableSuggestions: false,
                              onChanged: (_) => _onFieldChanged(),
                            ),
                          _accountStatus(checkState),
                          const SizedBox(height: 20),
                          _label(ref.tr('recipient.name_label')),
                          TextField(
                            controller: _nameController,
                            textCapitalization: TextCapitalization.words,
                            onChanged: (_) => _onFieldChanged(),
                          ),
                          _nameStatus(checkState, authorize),
                          const SizedBox(height: 20),
                          _label(ref.tr('recipient.reference_label')),
                          TextField(
                            controller: _referenceController,
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        if (authorize.issue == AuthorizeIssue.lockExpired) ...[
                          const SizedBox(height: 20),
                          _note(
                            Icons.timer_off_outlined,
                            ref.tr('recipient.lock_expired'),
                            AppColors.danger,
                          ),
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: Text(ref.tr('common.back')),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: CustomButton(
                    label: authorizeLabel,
                    onPressed: authorize.canAuthorize ? _authorize : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
