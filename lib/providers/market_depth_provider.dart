import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/market_depth_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

enum MarketDepthStatus { unavailable, loading, ready, error }

/// F4.2 — queue depth and corridor health (`GET /market/depth`).
class MarketDepthState {
  const MarketDepthState({
    this.status = MarketDepthStatus.unavailable,
    this.corridors = const [],
    this.errorKey,
  });

  final MarketDepthStatus status;
  final List<CorridorDepth> corridors;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class MarketDepthNotifier extends Notifier<MarketDepthState> {
  @override
  MarketDepthState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        state = const MarketDepthState();
      }
    });
    return const MarketDepthState();
  }

  /// Needs the server config first (the corridors name currencies by code).
  Future<void> load() async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const MarketDepthState();
      return;
    }

    state = MarketDepthState(
      status: MarketDepthStatus.loading,
      corridors: state.corridors,
    );
    try {
      final corridors =
          await ref.read(ratesRepositoryProvider).fetchDepth(config);
      state = MarketDepthState(
        status: MarketDepthStatus.ready,
        corridors: corridors,
      );
    } on ApiException catch (e) {
      state = MarketDepthState(
        status: MarketDepthStatus.error,
        errorKey: e.messageKey,
      );
    }
  }
}

final marketDepthProvider =
    NotifierProvider<MarketDepthNotifier, MarketDepthState>(
  MarketDepthNotifier.new,
);