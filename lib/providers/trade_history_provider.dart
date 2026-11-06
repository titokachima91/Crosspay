import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

/// F3.7.4 — trade history (GET /trades).
///
/// Kept in its own provider so the live tracking state
/// (tradeProvider) is never disturbed. Until the backend ships
/// GET /trades the load fails and [TradeHistoryState.notConnected]
/// is true, so the screen can say "not connected" plainly
/// (product rule 5). Simulated data lives ONLY in preview/.
class TradeHistoryState {
  const TradeHistoryState({
    this.trades = const [],
    this.loading = false,
    this.notConnected = false,
  });

  final List<Trade> trades;
  final bool loading;

  /// True when the server could not be reached or the endpoint is
  /// not available yet. The UI shows a plain message, never fake data.
  final bool notConnected;

  TradeHistoryState copyWith({
    List<Trade>? trades,
    bool? loading,
    bool? notConnected,
  }) {
    return TradeHistoryState(
      trades: trades ?? this.trades,
      loading: loading ?? this.loading,
      notConnected: notConnected ?? this.notConnected,
    );
  }
}

class TradeHistoryNotifier extends Notifier<TradeHistoryState> {
  @override
  TradeHistoryState build() => const TradeHistoryState();

  /// Loads the trade history from the server.
  Future<void> load() async {
    state = state.copyWith(loading: true, notConnected: false);
    try {
      final repo = ref.read(tradeRepositoryProvider);
      final config = ref.read(appConfigProvider).config;
      final trades = await repo.getTrades(config);
      state = TradeHistoryState(trades: trades, loading: false);
    } catch (_) {
      // Endpoint missing or server unreachable: say so plainly.
      state = state.copyWith(loading: false, notConnected: true);
    }
  }
}

final tradeHistoryProvider =
    NotifierProvider<TradeHistoryNotifier, TradeHistoryState>(
        TradeHistoryNotifier.new);