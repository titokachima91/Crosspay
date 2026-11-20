import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/security/app_lock_provider.dart';
import 'package:crosspay_app/core/security/pin_manager.dart';
import 'package:crosspay_app/features/account/screens/account_tab_screen.dart';
import 'package:crosspay_app/features/ledger/screens/transaction_history_screen.dart';
import 'package:crosspay_app/features/transaction/screens/home_dashboard_screen.dart';
import 'package:crosspay_app/features/transaction/screens/market_depth_screen.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/widgets/persistent_bottom_nav.dart';

/// The signed-in app: four tabs under one navigation bar.
class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key});

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _gated = false;
  bool _gateRunning = false;
  bool _visible = false;
  bool _lockError = false;
  Timer? _bannerTimer;
  String _bannerSignature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _gate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bannerTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused && _visible) {
      // Never leave the tabs visible in the app switcher. The session stays;
      // the gate runs again when the app resumes.
      setState(() => _visible = false);
    } else if (state == AppLifecycleState.resumed && !_visible) {
      _gate(force: true);
    }
  }

  /// Rebuild when a published banner window opens or closes while the shell
  /// stays mounted. One boundary at a time; the next build schedules the next.
  void _syncBannerTimer(List<AppBanner> banners) {
    if (!mounted) return;
    final now = DateTime.now();
    DateTime? next;
    for (final banner in banners) {
      for (final at in [banner.startsAt, banner.endsAt]) {
        if (at.isAfter(now) && (next == null || at.isBefore(next))) {
          next = at;
        }
      }
    }
    final signature =
        '${banners.map((banner) => banner.id).join(',')}|${next?.toIso8601String() ?? ''}';
    if (signature == _bannerSignature) return;
    _bannerSignature = signature;
    _bannerTimer?.cancel();
    _bannerTimer = null;
    if (next == null) return;
    _bannerTimer = Timer(
      next.difference(now) + const Duration(seconds: 1),
      () {
        if (mounted) setState(() {});
      },
    );
  }

  /// F5.3 — app-lock gate. Runs on shell mount, when the app resumes, and when
  /// the person taps "Lock app now". The session is untouched: biometrics/PIN
  /// only hide and reveal the signed-in surface. Sign-out is separate.
  Future<void> _gate({bool force = false}) async {
    if (_gateRunning) return;
    if (!force && _gated) return;
    _gateRunning = true;
    _gated = true;
    if (_lockError) {
      setState(() => _lockError = false);
    }
    bool unlocked;
    try {
      unlocked = await PinManager().ensureUnlocked(
        context,
        biometricReason:
            ref.read(localizationProvider).t('security.biometric_reason'),
      );
    } catch (e) {
      // A broken secure-storage/keystore state must not silently open a
      // money app. Stay on the locked screen and offer retry or sign-out.
      if (!mounted) {
        _gateRunning = false;
        return;
      }
      setState(() {
        _visible = false;
        _lockError = true;
      });
      _gateRunning = false;
      return;
    }
    if (!mounted) {
      _gateRunning = false;
      return;
    }
    setState(() {
      _visible = unlocked;
      _lockError = false;
    });
    _gateRunning = false;
  }

  Future<void> _switchAccountFromLock() async {
    try {
      await PinManager().clear();
    } catch (_) {
      // The session still ends if the local lock cannot be cleared.
    }
    await ref.read(authProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.splash,
      (route) => false,
    );
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

    final config = ref.watch(appConfigProvider).config;
    ref.listen<int>(appLockProvider, (previous, next) {
      if (previous != null && next > previous) {
        setState(() => _visible = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gate(force: true);
        });
      }
    });
    final service = config.service;
    final now = DateTime.now();
    final banners = [
      for (final banner in config.banners)
        if (banner.isActiveAt(now)) banner,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncBannerTimer(config.banners);
    });
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: !_visible
            ? _LockedView(
                onUnlock: () => _gate(force: true),
                onSwitchAccount: _switchAccountFromLock,
                lockError: _lockError,
              )
            : Column(
                children: [
                  if ((service != null && service.isActive) ||
                      banners.isNotEmpty)
                    Column(
                      children: [
                        if (service != null && service.isActive)
                          _ServiceBanner(status: service),
                        for (final banner in banners)
                          _AppBanner(
                            key: ValueKey(banner.id),
                            banner: banner,
                          ),
                      ],
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: _index,
                      children: const [
                        HomeDashboardScreen(),
                        TransactionHistoryScreen(),
                        MarketDepthScreen(),
                        AccountTabScreen(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: PersistentBottomNav(
        currentIndex: _index,
        onSelected: (index) => setState(() => _index = index),
      ),
    );
  }
}

class _LockedView extends StatelessWidget {
  const _LockedView({
    required this.onUnlock,
    required this.onSwitchAccount,
    this.lockError = false,
  });

  final VoidCallback onUnlock;
  final VoidCallback onSwitchAccount;
  final bool lockError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                lockError ? Icons.lock_person_outlined : Icons.lock_outline,
                size: 56,
                color: lockError ? scheme.error : scheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                lockError ? 'App lock unavailable' : 'App locked',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                lockError
                    ? 'The device lock could not be checked, so the app stayed '
                        'closed. Try again, or sign in with a different account '
                        'using OTP.'
                    : 'Use your fingerprint, face or PIN to continue. Your '
                        'session is still signed in; OTP is only needed for a '
                        'new sign-in.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(lockError ? 'Try again' : 'Unlock'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onSwitchAccount,
                child: const Text('Sign in with a different account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceBanner extends StatelessWidget {
  const _ServiceBanner({required this.status});

  final ServiceStatus status;

  @override
  Widget build(BuildContext context) {
    final pauses = [
      if (status.quotesPaused) 'new quotes',
      if (status.tradesPaused) 'new transfers',
    ];
    final fallback = pauses.isEmpty
        ? 'Service notice'
        : '${pauses.join(' and ')} are paused for a short maintenance window.';
    return Material(
      color: AppColors.warning.withOpacity(0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, color: AppColors.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                status.message?.trim().isNotEmpty == true
                    ? status.message!.trim()
                    : fallback,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A scheduled banner approved in the admin portal. The text comes from the
/// server in English and Swahili; the severity only selects colour and icon.
class _AppBanner extends ConsumerWidget {
  const _AppBanner({super.key, required this.banner});

  final AppBanner banner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeCodeProvider);
    final (color, icon) = switch (banner.severity) {
      BannerSeverity.critical => (AppColors.danger, Icons.error_outline),
      BannerSeverity.warning => (
          AppColors.warning,
          Icons.warning_amber_rounded,
        ),
      BannerSeverity.info => (AppColors.navy, Icons.campaign_outlined),
    };
    return Material(
      color: color.withOpacity(0.10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, color: color, size: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                banner.messageFor(locale),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Each tab is now its real screen: Home (F3.1), Ledger (F4.1),
/// Rates / market depth (F4.2) and Account (F4.1 / F5.1 / F5.2 / F5.3).
