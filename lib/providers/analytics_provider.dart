import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/analytics_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum AnalyticsStatus { unavailable, loading, ready, error }

/// F4.1 — spending analytics (`GET /trades/analytics`). The numbers are the
/// server's; the app adds nothing up on the device.
class AnalyticsState {
  const AnalyticsState({
    this.status = AnalyticsStatus.unavailable,
    this.analytics,
    this.errorKey,
  });

  final AnalyticsStatus status;
  final TradeAnalytics? analytics;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class AnalyticsNotifier extends Notifier<AnalyticsState> {
  @override
  AnalyticsState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        state = const AnalyticsState();
      }
    });
    return const AnalyticsState();
  }

  /// Needs the server config first (currency codes come from it).
  Future<void> load() async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const AnalyticsState();
      return;
    }

    state = AnalyticsState(
      status: AnalyticsStatus.loading,
      analytics: state.analytics,
    );
    try {
      final analytics =
          await ref.read(tradeRepositoryProvider).fetchAnalytics(config);
      state = AnalyticsState(
        status: AnalyticsStatus.ready,
        analytics: analytics,
      );
    } on ApiException catch (e) {
      state = AnalyticsState(
        status: AnalyticsStatus.error,
        errorKey: e.messageKey,
      );
    }
  }
}

final analyticsProvider =
    NotifierProvider<AnalyticsNotifier, AnalyticsState>(AnalyticsNotifier.new);