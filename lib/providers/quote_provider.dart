import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/utils/duration_format.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum QuoteStatus { idle, loading, ready, expired, error }

class QuoteState {
  const QuoteState({
    this.sendCurrency,
    this.receiveCurrency,
    this.sendAmountMinor = 0,
    this.quote,
    this.selectedRoute,
    this.status = QuoteStatus.idle,
    this.remaining = Duration.zero,
    this.errorKey,
    this.errorCode,
  });

  /// Null until the person (or the first screen) picks one.
  final Currency? sendCurrency;
  final Currency? receiveCurrency;
  final int sendAmountMinor;
  final Quote? quote;
  final RouteType? selectedRoute;
  final QuoteStatus status;
  final Duration remaining;

  /// Localization key for the last failure (e.g. 'error.network') and the
  /// server's error code for a more specific message.
  final String? errorKey;
  final String? errorCode;

  bool get canRequestQuote =>
      sendCurrency != null &&
      receiveCurrency != null &&
      sendCurrency != receiveCurrency &&
      sendAmountMinor > 0;

  /// Countdown label for the rate-lock banner, e.g. "04:58".
  String get remainingLabel => formatClock(remaining);

  QuoteState copyWith({
    Currency? sendCurrency,
    Currency? receiveCurrency,
    int? sendAmountMinor,
    Quote? quote,
    bool clearQuote = false,
    RouteType? selectedRoute,
    bool clearRoute = false,
    QuoteStatus? status,
    Duration? remaining,
    String? errorKey,
    String? errorCode,
    bool clearError = false,
  }) {
    return QuoteState(
      sendCurrency: sendCurrency ?? this.sendCurrency,
      receiveCurrency: receiveCurrency ?? this.receiveCurrency,
      sendAmountMinor: sendAmountMinor ?? this.sendAmountMinor,
      quote: clearQuote ? null : (quote ?? this.quote),
      selectedRoute: clearRoute ? null : (selectedRoute ?? this.selectedRoute),
      status: status ?? this.status,
      remaining: remaining ?? this.remaining,
      errorKey: clearError ? null : (errorKey ?? this.errorKey),
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
    );
  }
}

/// Holds the converter inputs and the current rate lock. The lock length is
/// whatever the server put in the quote's expiry time.
class QuoteNotifier extends Notifier<QuoteState> {
  Timer? _timer;
  int _requestGeneration = 0;

  @override
  QuoteState build() {
    ref.onDispose(() => _timer?.cancel());
    // A different person must never see the previous person's inputs.
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        reset();
      }
    });
    return const QuoteState();
  }

  /// Any change to the inputs invalidates the current quote and any request
  /// still on its way.
  void _edit({Currency? send, Currency? receive, int? amount}) {
    _timer?.cancel();
    _requestGeneration++;
    state = state.copyWith(
      sendCurrency: send,
      receiveCurrency: receive,
      sendAmountMinor: amount,
      clearQuote: true,
      clearRoute: true,
      clearError: true,
      status: QuoteStatus.idle,
      remaining: Duration.zero,
    );
  }

  void setSendCurrency(Currency c) => _edit(send: c);

  void setReceiveCurrency(Currency c) => _edit(receive: c);

  void setSendAmount(int minor) => _edit(amount: minor);

  /// Only routes the server marked available can be selected.
  void selectRoute(RouteType route) {
    final option = state.quote?.forRoute(route);
    if (option == null || !option.isAvailable) return;
    state = state.copyWith(selectedRoute: route);
  }

  /// Asks the server for a locked quote for the current inputs.
  Future<void> requestQuote() async {
    final inputs = state;
    final send = inputs.sendCurrency;
    final receive = inputs.receiveCurrency;
    if (!inputs.canRequestQuote || send == null || receive == null) return;

    quoteRequested();
    final generation = ++_requestGeneration;
    try {
      final quote = await ref.read(tradeRepositoryProvider).quote(
            sendCurrency: send,
            receiveCurrency: receive,
            sendAmountMinor: inputs.sendAmountMinor,
          );
      if (generation != _requestGeneration) return;
      quoteReceived(quote);
    } on ApiException catch (e) {
      if (generation != _requestGeneration) return;
      quoteFailed(e.messageKey, code: e.code);
    }
  }

  void quoteRequested() {
    _timer?.cancel();
    state = state.copyWith(
      status: QuoteStatus.loading,
      clearQuote: true,
      clearRoute: true,
      clearError: true,
    );
  }

  /// Call when the server returns a locked quote. Starts the countdown.
  void quoteReceived(Quote quote) {
    _timer?.cancel();
    final preselected = quote.defaultRoute?.route;
    state = state.copyWith(
      quote: quote,
      selectedRoute: preselected,
      clearRoute: preselected == null,
      status: QuoteStatus.ready,
      remaining: quote.remainingAt(DateTime.now()),
      clearError: true,
    );
    _tick();
    if (state.status == QuoteStatus.ready) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void quoteFailed(String errorKey, {String? code}) {
    _timer?.cancel();
    state = state.copyWith(
      status: QuoteStatus.error,
      errorKey: errorKey,
      errorCode: code,
    );
  }

  void reset() {
    _timer?.cancel();
    _requestGeneration++;
    state = const QuoteState();
  }

  void _tick() {
    final q = state.quote;
    if (q == null) return;
    final remaining = q.remainingAt(DateTime.now());
    if (remaining == Duration.zero) {
      _timer?.cancel();
      state = state.copyWith(
        status: QuoteStatus.expired,
        remaining: Duration.zero,
      );
    } else {
      state = state.copyWith(remaining: remaining);
    }
  }
}

final quoteProvider =
    NotifierProvider<QuoteNotifier, QuoteState>(QuoteNotifier.new);
