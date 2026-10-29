import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/quote_model.dart';

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
    this.errorMessage,
  });

  /// Null until the user (or the server config) picks one.
  final Currency? sendCurrency;
  final Currency? receiveCurrency;
  final int sendAmountMinor;
  final Quote? quote;
  final RouteType? selectedRoute;
  final QuoteStatus status;
  final Duration remaining;
  final String? errorMessage;

  bool get canRequestQuote =>
      sendCurrency != null &&
      receiveCurrency != null &&
      sendCurrency != receiveCurrency &&
      sendAmountMinor > 0;

  /// Countdown label for the rate-lock banner, e.g. "04:58".
  String get remainingLabel {
    final m = remaining.inMinutes.toString().padLeft(2, '0');
    final s = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

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
    String? errorMessage,
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
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Holds the converter inputs and the current rate lock. The lock length is
/// whatever the server put in the quote's expiry time.
class QuoteNotifier extends Notifier<QuoteState> {
  Timer? _timer;

  @override
  QuoteState build() {
    ref.onDispose(() => _timer?.cancel());
    return const QuoteState();
  }

  /// Any change to the inputs invalidates the current quote.
  void _edit({Currency? send, Currency? receive, int? amount}) {
    _timer?.cancel();
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

  void quoteFailed(String message) {
    _timer?.cancel();
    state = state.copyWith(status: QuoteStatus.error, errorMessage: message);
  }

  void reset() {
    _timer?.cancel();
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
