import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_constants.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/features/onboarding/auth_entry_mode.dart';
import 'package:crosspay_app/features/onboarding/widgets/corridor_health_card.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';
import 'package:crosspay_app/widgets/language_switcher.dart';

/// Screen 1.1: splash, language switcher and live corridor health.
class SplashLanguageScreen extends ConsumerStatefulWidget {
  const SplashLanguageScreen({super.key});

  @override
  ConsumerState<SplashLanguageScreen> createState() =>
      _SplashLanguageScreenState();
}

class _SplashLanguageScreenState extends ConsumerState<SplashLanguageScreen> {
  bool _checkingSession = true;
  bool _hasStoredSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    try {
      final token = await ref.read(tokenStorageProvider).readRefreshToken();
      _hasStoredSession = token != null && token.isNotEmpty;
    } catch (_) {
      _hasStoredSession = false;
    }
    if (!mounted) return;
    await _load();
  }

  Future<bool> _storedSessionExists() async {
    try {
      final token = await ref.read(tokenStorageProvider).readRefreshToken();
      return token != null && token.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _load() async {
    await ref.read(appConfigProvider.notifier).load();
    if (!mounted) return;
    if (ref.read(appConfigProvider).status == ConfigStatus.ready) {
      await ref.read(ratesProvider.notifier).load();
      if (!mounted) return;
      // F5.3 — a stored refresh token sends a returning merchant straight
      // into the app. No token means the normal sign-in flow.
      final restored = await ref.read(authProvider.notifier).restoreSession();
      if (!mounted) return;
      switch (restored) {
        case SessionRestore.restored:
          Navigator.of(context).pushNamedAndRemoveUntil(
            AppRoutes.home,
            (route) => false,
          );
          return;
        case SessionRestore.profileIncomplete:
          Navigator.of(context).pushNamedAndRemoveUntil(
            AppRoutes.kyc,
            (route) => false,
          );
          return;
        case SessionRestore.noSession:
        case SessionRestore.unavailable:
          break;
      }
    }
    final stored = await _storedSessionExists();
    if (!mounted) return;
    setState(() {
      _hasStoredSession = stored;
      _checkingSession = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: LanguageSwitcher(),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                      children: [
                        const _LogoMark(),
                        const SizedBox(height: 16),
                        Text(
                          AppConstants.appName,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          ref.tr('app.tagline'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 24),
                        const _HowItWorksCard(),
                        const SizedBox(height: 16),
                        CorridorHealthCard(onRetry: _load),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: _checkingSession
                      ? const SizedBox(
                          height: 52,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : _hasStoredSession
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CustomButton(
                                  label: ref.tr('splash.continue'),
                                  onPressed: _load,
                                  accent: true,
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pushNamed(
                                    AppRoutes.phone,
                                    arguments: {
                                      'mode': AuthEntryMode.signIn.name,
                                    },
                                  ),
                                  child: Text(ref.tr('splash.sign_in_code')),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CustomButton(
                                  label: ref.tr('splash.sign_in'),
                                  onPressed: () =>
                                      Navigator.of(context).pushNamed(
                                    AppRoutes.phone,
                                    arguments: {
                                      'mode': AuthEntryMode.signIn.name,
                                    },
                                  ),
                                  accent: true,
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pushNamed(
                                    AppRoutes.phone,
                                    arguments: {
                                      'mode': AuthEntryMode.createAccount.name,
                                    },
                                  ),
                                  child: Text(ref.tr('splash.create_account')),
                                ),
                              ],
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

/// Temporary letter mark until a logo file is supplied.
class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) {
    const name = AppConstants.appName;
    final initial = name.isEmpty ? '' : name.substring(0, 1);
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Container(
        width: 88,
        height: 88,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          initial,
          style: TextStyle(
            color: scheme.onPrimary,
            fontSize: 44,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _HowItWorksCard extends ConsumerWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, color: AppColors.emerald),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ref.tr('splash.how_title').toUpperCase(),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Bullet(text: ref.tr('splash.zero_balance')),
          const SizedBox(height: 8),
          _Bullet(text: ref.tr('splash.direct_settlement')),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('\u2022  ', style: Theme.of(context).textTheme.bodyMedium),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}
