import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 1.4: business profile and KYC.
///
/// The ID / TIN typed here is sent to the server and nowhere else: it is not
/// stored, not kept in app state and not logged.
class KycProfileScreen extends ConsumerStatefulWidget {
  const KycProfileScreen({super.key});

  @override
  ConsumerState<KycProfileScreen> createState() => _KycProfileScreenState();
}

class _KycProfileScreenState extends ConsumerState<KycProfileScreen> {
  // The onboarding flow has two steps by design: phone, then business KYC.
  static const int _step = 2;
  static const int _totalSteps = 2;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _idController = TextEditingController();
  TradingHub? _hub;

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
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    setState(() {});
    if (ref.read(authProvider).errorKey != null) {
      ref.read(authProvider.notifier).clearError();
    }
  }

  Future<void> _submit(TradingHub hub) async {
    FocusScope.of(context).unfocus();
    final accepted = await ref.read(authProvider.notifier).submitKyc(
          businessName: _nameController.text.trim(),
          hubId: hub.id,
          idNumber: _idController.text.trim(),
        );
    if (!mounted) return;

    if (accepted) {
      _idController.clear();
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.home,
        (route) => false,
      );
    }
  }

  String _hubLabel(TradingHub hub, List<Country> countries) {
    for (final c in countries) {
      if (c.code == hub.countryCode) return '${hub.name} (${c.name})';
    }
    return hub.name;
  }

  @override
  Widget build(BuildContext context) {
    // If the session ends (for example the token expired), go back to the start.
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (previous?.status != AuthStatus.signedOut &&
          next.status == AuthStatus.signedOut) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.splash,
          (route) => false,
        );
      }
    });

    final configState = ref.watch(appConfigProvider);
    final hubs = configState.config.hubs;

    final Widget body;
    if (configState.status == ConfigStatus.ready && hubs.isNotEmpty) {
      body = _buildForm(configState.config);
    } else {
      final String? message;
      if (configState.status == ConfigStatus.ready) {
        message = ref.tr('kyc.no_hubs');
      } else if (configState.status == ConfigStatus.error) {
        message = ref.tr(configState.errorKey ?? 'error.unknown');
      } else {
        message = null; // still loading
      }
      body = _buildUnavailable(message);
    }

    return Scaffold(
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

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ref.tr('kyc.step', params: {
            'current': '$_step',
            'total': '$_totalSteps',
          }),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColors.emerald,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          ref.tr('kyc.title'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ],
    );
  }

  Widget _buildUnavailable(String? message) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: 32),
          if (message == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => ref.read(appConfigProvider.notifier).load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        ],
      ),
    );
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

  Widget _buildForm(AppConfig config) {
    final auth = ref.watch(authProvider);
    final submitting = auth.status == AuthStatus.submittingKyc;
    final hub = config.hubs.contains(_hub) ? _hub : null;

    final canSubmit = !submitting &&
        hub != null &&
        _nameController.text.trim().isNotEmpty &&
        _idController.text.trim().isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                const SizedBox(height: 24),
                _label(ref.tr('kyc.business_name')),
                TextField(
                  controller: _nameController,
                  enabled: !submitting,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.organizationName],
                  onChanged: (_) => _onFieldChanged(),
                ),
                const SizedBox(height: 20),
                _label(ref.tr('kyc.hub')),
                DropdownButtonFormField<TradingHub>(
                  value: hub,
                  isExpanded: true,
                  hint: Text(ref.tr('kyc.hub_hint')),
                  items: [
                    for (final h in config.hubs)
                      DropdownMenuItem<TradingHub>(
                        value: h,
                        child: Text(
                          _hubLabel(h, config.countries),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: submitting
                      ? null
                      : (selected) {
                          setState(() => _hub = selected);
                          if (ref.read(authProvider).errorKey != null) {
                            ref.read(authProvider.notifier).clearError();
                          }
                        },
                ),
                const SizedBox(height: 20),
                _label(ref.tr('kyc.id_label')),
                TextField(
                  controller: _idController,
                  enabled: !submitting,
                  keyboardType: TextInputType.text,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  onChanged: (_) => _onFieldChanged(),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ref.tr('kyc.privacy_notice'),
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
            label: ref.tr('kyc.submit'),
            isLoading: submitting,
            onPressed: canSubmit ? () => _submit(hub) : null,
          ),
        ),
      ],
    );
  }
}
