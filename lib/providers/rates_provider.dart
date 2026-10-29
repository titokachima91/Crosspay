import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/quote_model.dart';

/// "unavailable" means no rate feed is connected. Screens must say so plainly.
enum RatesStatus { unavailable, loading, live, error }

class RatesState {
  const RatesState({
    this.status = RatesStatus.unavailable,
    this.rates = const [],
    this.p2pDensityPercent,
    this.bankSweepPercent,
    this.errorMessage,
  });

  final RatesStatus status;
  final List<CorridorRate> rates;

  /// Queue Liquidity Health gauges on Screen 4.1 (0 to 100).
  final int? p2pDensityPercent;
  final int? bankSweepPercent;
  final String? errorMessage;

  CorridorRate? rateFor(Currency from, Currency to) {
    for (final r in rates) {
      if (r.from == from && r.to == to) return r;
    }
    return null;
  }

  RatesState copyWith({
    RatesStatus? status,
    List<CorridorRate>? rates,
    int? p2pDensityPercent,
    int? bankSweepPercent,
    String? errorMessage,
  }) {
    return RatesState(
      status: status ?? this.status,
      rates: rates ?? this.rates,
      p2pDensityPercent: p2pDensityPercent ?? this.p2pDensityPercent,
      bankSweepPercent: bankSweepPercent ?? this.bankSweepPercent,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class RatesNotifier extends Notifier<RatesState> {
  @override
  RatesState build() => const RatesState();

  void loading() => state = state.copyWith(status: RatesStatus.loading);

  void ratesUpdated({
    required List<CorridorRate> rates,
    int? p2pDensityPercent,
    int? bankSweepPercent,
  }) {
    state = state.copyWith(
      status: RatesStatus.live,
      rates: rates,
      p2pDensityPercent: p2pDensityPercent,
      bankSweepPercent: bankSweepPercent,
    );
  }

  void failed(String message) =>
      state = state.copyWith(status: RatesStatus.error, errorMessage: message);
}

final ratesProvider =
    NotifierProvider<RatesNotifier, RatesState>(RatesNotifier.new);
