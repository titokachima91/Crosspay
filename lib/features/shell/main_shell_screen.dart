import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
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

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  int _index = 0;
  bool _gated = false;
  bool _visible = false;
  Timer? _bannerTimer;
  String _bannerSignature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _gate());
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
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

  /// F5.3 — app-lock gate. Runs once per shell mount: when a PIN is
  /// set the person must enter it before the tabs become usable.
  /// Cancel pops back to the previous screen (never traps in a loop).
  Future<void> _gate() async {
    if (_gated) return;
    _gated = true;
    bool unlocked;
    try {
      unlocked = await PinManager().ensureUnlocked(
        context,
        biometricReason:
            ref.read(localizationProvider).t('security.biometric_reason'),
      );
    } catch (e) {
      // Secure storage unavailable (tests, broken keystore): fail
      // open so a storage error never locks the person out of their
      // own device. PIN guards app surface only; session security
      // stays with the server (refresh tokens, timeouts).
      unlocked = true;
    }
    if (!mounted) return;
    if (unlocked) {
      setState(() => _visible = true);
    } else {
      // Cancelled the PIN prompt: leave the shell.
      Navigator.of(context).pop();
    }
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
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.emerald))
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
