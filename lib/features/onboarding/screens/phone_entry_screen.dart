import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';
import 'package:crosspay_app/core/utils/national_number_formatter.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/features/onboarding/auth_entry_mode.dart';
import 'package:crosspay_app/features/onboarding/widgets/carrier_badge_chip.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 1.2: business phone number entry with network suggestion.
class PhoneEntryScreen extends ConsumerStatefulWidget {
  const PhoneEntryScreen({super.key});

  @override
  ConsumerState<PhoneEntryScreen> createState() => _PhoneEntryScreenState();
}

class _PhoneEntryScreenState extends ConsumerState<PhoneEntryScreen> {
  AuthEntryMode get _mode => AuthEntryMode.fromArguments(
        ModalRoute.of(context)?.settings.arguments,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(appConfigProvider).status == ConfigStatus.unavailable) {
        ref.read(appConfigProvider.notifier).load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    final scheme = Theme.of(context).colorScheme;

    final Widget body;
    if (config.status == ConfigStatus.ready &&
        config.config.countries.isNotEmpty) {
      body = _PhoneForm(config: config.config, mode: _mode);
    } else if (config.status == ConfigStatus.ready) {
      body = _UnavailableBody(
        mode: _mode,
        message: ref.tr('phone.no_countries'),
        onRetry: () => ref.read(appConfigProvider.notifier).load(),
      );
    } else if (config.status == ConfigStatus.error) {
      body = _UnavailableBody(
        mode: _mode,
        message: ref.tr(config.errorKey ?? 'error.unknown'),
        onRetry: () => ref.read(appConfigProvider.notifier).load(),
      );
    } else {
      body = _UnavailableBody(mode: _mode); // still loading
    }

    return Scaffold(
      appBar: AppBar(
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
            child: body,
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.mode});

  final AuthEntryMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ref.tr(mode.titleKey),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          ref.tr(mode.subtitleKey),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// Shown while the server data is loading or when it cannot be reached.
class _UnavailableBody extends ConsumerWidget {
  const _UnavailableBody({required this.mode, this.message, this.onRetry});

  final AuthEntryMode mode;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(mode: mode),
          const SizedBox(height: 32),
          if (message == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(ref.tr('common.retry')),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _PhoneForm extends ConsumerStatefulWidget {
  const _PhoneForm({required this.config, required this.mode});

  final AppConfig config;
  final AuthEntryMode mode;

  @override
  ConsumerState<_PhoneForm> createState() => _PhoneFormState();
}

class _PhoneFormState extends ConsumerState<_PhoneForm> {
  final TextEditingController _controller = TextEditingController();
  Country? _country;

  /// The user's choice, or the first country the server listed.
  Country get _selectedCountry {
    final countries = widget.config.countries;
    final chosen = _country;
    return (chosen != null && countries.contains(chosen))
        ? chosen
        : countries.first;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onCountryChanged(Country country) {
    setState(() => _country = country);
    // Re-apply the new length limit to what is already typed.
    final formatter =
        NationalNumberFormatter(maxDigits: country.nationalNumberLength);
    _controller.value =
        formatter.formatEditUpdate(_controller.value, _controller.value);
  }

  void _onNumberChanged() {
    setState(() {});
    if (ref.read(authProvider).errorKey != null) {
      ref.read(authProvider.notifier).clearError();
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final phone =
        PhoneUtils.toInternational(_selectedCountry, _controller.text);
    final sent = await ref.read(authProvider.notifier).requestOtp(phone);
    if (!mounted) return;
    if (sent) {
      Navigator.of(context).pushNamed(
        AppRoutes.otp,
        arguments: {'mode': widget.mode.name},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final country = _selectedCountry;
    final auth = ref.watch(authProvider);
    final sending = auth.status == AuthStatus.requestingOtp;
    final scheme = Theme.of(context).colorScheme;

    final complete = PhoneUtils.isComplete(country, _controller.text);
    final carrier = PhoneUtils.detectCarrier(
      country: country,
      input: _controller.text,
      carriers: widget.config.carriers,
    );

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(mode: widget.mode),
                const SizedBox(height: 24),
                Text(
                  ref.tr('phone.label').toUpperCase(),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 56,
                      child: _CountryDropdown(
                        countries: widget.config.countries,
                        selected: country,
                        enabled: !sending,
                        onChanged: _onCountryChanged,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !sending,
                        keyboardType: TextInputType.phone,
                        autofillHints: const [
                          AutofillHints.telephoneNumberNational
                        ],
                        inputFormatters: [
                          NationalNumberFormatter(
                            maxDigits: country.nationalNumberLength,
                          ),
                        ],
                        onChanged: (_) => _onNumberChanged(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (carrier != null)
                  CarrierBadgeChip(
                    text: ref.tr(
                      'phone.carrier_likely',
                      params: {'name': carrier.name},
                    ),
                  )
                else if (complete)
                  Text(
                    ref.tr('phone.carrier_unknown'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ref.tr('phone.carrier_info'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                if (auth.errorKey != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    ref.trError(key: auth.errorKey!, code: auth.errorCode),
                    style: const TextStyle(color: AppColors.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: CustomButton(
            label: ref.tr('phone.continue'),
            isLoading: sending,
            onPressed: complete ? _submit : null,
          ),
        ),
      ],
    );
  }
}

class _CountryDropdown extends StatelessWidget {
  const _CountryDropdown({
    required this.countries,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final List<Country> countries;
  final Country selected;
  final bool enabled;
  final ValueChanged<Country> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Country>(
          value: selected,
          items: [
            for (final c in countries)
              DropdownMenuItem<Country>(
                value: c,
                child:
                    Text('${countryFlag(c.code)} ${c.name} (+${c.dialCode})'),
              ),
          ],
          selectedItemBuilder: (context) => [
            for (final c in countries)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('${countryFlag(c.code)} +${c.dialCode}'),
              ),
          ],
          onChanged: enabled
              ? (country) {
                  if (country != null) onChanged(country);
                }
              : null,
        ),
      ),
    );
  }
}
