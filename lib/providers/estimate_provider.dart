import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum EstimateStatus { idle, loading, ready, error }

class EstimateState {
  const EstimateState({
    this.status = EstimateStatus.idle,
    this.estimate,
    this.errorKey,
  });

  final EstimateStatus status;

  /// While [status] is loading this still holds the previous answer, so the
  /// screen can show it dimmed instead of flickering.
  final Estimate? estimate;
  final String? errorKey;
}

/// How long to wait after the last keystroke before asking the server.
final estimateDebounceProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 500),
);

/// Keeps an indicative estimate in step with the converter inputs held by
/// the quote provider.
class EstimateNotifier extends Notifier<EstimateState> {
  Timer? _debounce;
  int _generation = 0;

  @override
  EstimateState build() {
    ref.onDispose(() => _debounce?.cancel());

    ref.listen<QuoteState>(quoteProvider, (previous, next) {
      final changed = previous?.sendCurrency != next.sendCurrency ||
          previous?.receiveCurrency != next.receiveCurrency ||
          previous?.sendAmountMinor != next.sendAmountMinor;
      if (changed) _inputsChanged();
    });

    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        _debounce?.cancel();
        _generation++;
        state = const EstimateState();
      }
    });

    return const EstimateState();
  }

  void _inputsChanged() {
    _debounce?.cancel();
    _generation++; // any answer still on its way is now out of date

    final inputs = ref.read(quoteProvider);
    if (!inputs.canRequestQuote) {
      state = const EstimateState();
      return;
    }

    state = EstimateState(
      status: EstimateStatus.loading,
      estimate: state.estimate,
    );
    _debounce = Timer(ref.read(estimateDebounceProvider), _fetch);
  }

  Future<void> _fetch() async {
    final inputs = ref.read(quoteProvider);
    final send = inputs.sendCurrency;
    final receive = inputs.receiveCurrency;
    if (!inputs.canRequestQuote || send == null || receive == null) return;

    final generation = _generation;
    try {
      final estimate = await ref.read(tradeRepositoryProvider).estimate(
            sendCurrency: send,
            receiveCurrency: receive,
            sendAmountMinor: inputs.sendAmountMinor,
          );
      if (generation != _generation) return;
      state = EstimateState(status: EstimateStatus.ready, estimate: estimate);
    } on ApiException catch (e) {
      if (generation != _generation) return;
      state = EstimateState(
        status: EstimateStatus.error,
        errorKey: e.messageKey,
      );
    }
  }
}

final estimateProvider =
    NotifierProvider<EstimateNotifier, EstimateState>(EstimateNotifier.new);
