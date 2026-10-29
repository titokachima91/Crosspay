import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

/// "unavailable" means no rate data has been loaded. Screens must say so plainly.
enum RatesStatus { unavailable, loading, live, error }

class RatesState {
  const RatesState({
    this.status = RatesStatus.unavailable,
    this.rates = const [],
    this.p2pDensityPercent,
    this.bankSweepPercent,
    this.errorKey,
  });

  final RatesStatus status;
  final List<CorridorRate> rates;

  /// Queue Liquidity Health gauges on Screen 4.1 (0 to 100).
  final int? p2pDensityPercent;
  final int? bankSweepPercent;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;

  CorridorRate? rateFor(Currency from, Currency to) {
    for (final r in rates) {
      if (r.from == from && r.to == to) return r;
    }
    return null;
  }
}

class RatesNotifier extends Notifier<RatesState> {
  @override
  RatesState build() => const RatesState();

  /// Needs the server config first, because rates refer to currencies by code.
  /// A failed refresh clears old rates, so stale prices are never shown as live.
  Future<void> load() async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const RatesState();
      return;
    }

    state = RatesState(
      status: RatesStatus.loading,
      rates: state.rates,
      p2pDensityPercent: state.p2pDensityPercent,
      bankSweepPercent: state.bankSweepPercent,
    );

    try {
      final snapshot = await ref.read(ratesRepositoryProvider).fetch(config);
      state = RatesState(
        status: RatesStatus.live,
        rates: snapshot.rates,
        p2pDensityPercent: snapshot.p2pDensityPercent,
        bankSweepPercent: snapshot.bankSweepPercent,
      );
    } on ApiException catch (e) {
      state = RatesState(status: RatesStatus.error, errorKey: e.messageKey);
    }
  }
}

final ratesProvider =
    NotifierProvider<RatesNotifier, RatesState>(RatesNotifier.new);
