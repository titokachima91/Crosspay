import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum PaymentStatus { idle, starting, waiting, paid, notCompleted, error }

/// Turns the server's seconds into real durations. Tests make this fast.
final paymentDurationProvider = Provider<Duration Function(int seconds)>(
  (ref) => (seconds) => Duration(seconds: seconds),
);

class PaymentState {
  const PaymentState({
    this.status = PaymentStatus.idle,
    this.attemptKey,
    this.trade,
    this.collection,
    this.fallbackOpen = false,
    this.claimSent = false,
    this.errorKey,
    this.errorCode,
    this.pollErrorKey,
    this.actionErrorKey,
    this.actionErrorCode,
  });

  final PaymentStatus status;

  /// The authorization attempt this state belongs to.
  final String? attemptKey;
  final Trade? trade;
  final CollectionInstructions? collection;
  final bool fallbackOpen;
  final bool claimSent;

  /// Why starting failed (translatable key and server code).
  final String? errorKey;
  final String? errorCode;

  /// A hiccup while checking for the deposit; the checks keep going.
  final String? pollErrorKey;

  /// Why the last button action (manual payment claim, cancel) failed.
  final String? actionErrorKey;
  final String? actionErrorCode;

  PaymentState copyWith({
    PaymentStatus? status,
    Trade? trade,
    bool? fallbackOpen,
    bool? claimSent,
    String? pollErrorKey,
    bool clearPollError = false,
    String? actionErrorKey,
    String? actionErrorCode,
    bool clearActionError = false,
  }) {
    return PaymentState(
      status: status ?? this.status,
      attemptKey: attemptKey,
      trade: trade ?? this.trade,
      collection: collection,
      fallbackOpen: fallbackOpen ?? this.fallbackOpen,
      claimSent: claimSent ?? this.claimSent,
      errorKey: errorKey,
      errorCode: errorCode,
      pollErrorKey: clearPollError ? null : (pollErrorKey ?? this.pollErrorKey),
      actionErrorKey:
          clearActionError ? null : (actionErrorKey ?? this.actionErrorKey),
      actionErrorCode:
          clearActionError ? null : (actionErrorCode ?? this.actionErrorCode),
    );
  }
}

enum _Outcome { waiting, paid, notCompleted }

_Outcome _outcomeOf(TradeStatus status) => switch (status) {
      TradeStatus.pendingDeposit => _Outcome.waiting,
      TradeStatus.escrowed ||
      TradeStatus.matching ||
      TradeStatus.matched ||
      TradeStatus.disbursing ||
      TradeStatus.completed =>
        _Outcome.paid,
      TradeStatus.expired ||
      TradeStatus.refunded ||
      TradeStatus.failed ||
      TradeStatus.cancelled =>
        _Outcome.notCompleted,
    };

/// Starts the payment and watches for the deposit. Only the SERVER's trade
/// status decides that money arrived; the app never concludes it itself.
class PaymentNotifier extends Notifier<PaymentState> {
  Timer? _pollTimer;
  Timer? _fallbackTimer;
  bool _polling = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  PaymentState build() {
    ref.onDispose(() {
      _disposed = true;
      _stopTimers();
    });
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        reset();
      }
    });
    return const PaymentState();
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();
    _pollTimer = null;
    _fallbackTimer = null;
  }

  /// Sends the payment request using the attempt key created when the person
  /// tapped Authorize. Calling it again for the same attempt does not start a
  /// second payment (and the server would not allow one either).
  Future<void> start() async {
    final tradeState = ref.read(tradeProvider);
    final key = tradeState.attemptKey;
    final recipient = tradeState.recipient;
    final quoteState = ref.read(quoteProvider);
    final quote = quoteState.quote;
    final route = quoteState.selectedRoute;

    if (key == null || recipient == null || quote == null || route == null) {
      state = const PaymentState(
        status: PaymentStatus.error,
        errorKey: 'collect.missing_details',
      );
      return;
    }

    final sameAttempt = state.attemptKey == key;
    if (sameAttempt &&
        state.status != PaymentStatus.idle &&
        state.status != PaymentStatus.error) {
      return;
    }

    _stopTimers();
    final generation = ++_generation;
    state = PaymentState(status: PaymentStatus.starting, attemptKey: key);

    try {
      final result = await ref.read(tradeRepositoryProvider).initiate(
            quote: quote,
            route: route,
            recipient: recipient,
            idempotencyKey: key,
            config: ref.read(appConfigProvider).config,
          );
      if (generation != _generation || _disposed) return;

      ref.read(tradeProvider.notifier).tradeStarted(result.trade);
      state = PaymentState(
        status: PaymentStatus.waiting,
        attemptKey: key,
        trade: result.trade,
        collection: result.collection,
        fallbackOpen: !result.collection.pushSent,
      );
      if (_outcomeOf(result.trade.status) == _Outcome.waiting) {
        _startTimers(result.collection);
      } else {
        _applyTrade(result.trade);
      }
    } on ApiException catch (e) {
      if (generation != _generation || _disposed) return;
      state = PaymentState(
        status: PaymentStatus.error,
        attemptKey: key,
        errorKey: e.messageKey,
        errorCode: e.code,
      );
    }
  }

  void _startTimers(CollectionInstructions collection) {
    _stopTimers();
    final toDuration = ref.read(paymentDurationProvider);
    _pollTimer = Timer.periodic(
      toDuration(math.max(1, collection.pollIntervalSeconds)),
      (_) => _poll(),
    );
    if (collection.pushSent) {
      _fallbackTimer = Timer(
        toDuration(math.max(0, collection.pushTimeoutSeconds)),
        () {
          if (state.status == PaymentStatus.waiting) {
            state = state.copyWith(fallbackOpen: true);
          }
        },
      );
    }
  }

  Future<void> _poll() async {
    final trade = state.trade;
    if (_polling || state.status != PaymentStatus.waiting || trade == null) {
      return;
    }

    _polling = true;
    final generation = _generation;
    try {
      final updated = await ref
          .read(tradeRepositoryProvider)
          .fetchTrade(trade.id, ref.read(appConfigProvider).config);
      if (generation != _generation || _disposed) return;
      _applyTrade(updated);
    } on ApiException catch (e) {
      if (generation != _generation || _disposed) return;
      state = state.copyWith(pollErrorKey: e.messageKey);
    } finally {
      _polling = false;
    }
  }

  void _applyTrade(Trade trade) {
    ref.read(tradeProvider.notifier).tradeUpdated(trade);
    switch (_outcomeOf(trade.status)) {
      case _Outcome.waiting:
        state = state.copyWith(trade: trade, clearPollError: true);
      case _Outcome.paid:
        _stopTimers();
        state = state.copyWith(
          status: PaymentStatus.paid,
          trade: trade,
          clearPollError: true,
        );
      case _Outcome.notCompleted:
        _stopTimers();
        state = state.copyWith(
          status: PaymentStatus.notCompleted,
          trade: trade,
          clearPollError: true,
        );
    }
  }

  void toggleFallback() =>
      state = state.copyWith(fallbackOpen: !state.fallbackOpen);

  /// "I have completed manual payment": tells the server to look now. The
  /// server's own confirmation still decides.
  Future<void> claimManualPayment() async {
    final trade = state.trade;
    if (trade == null || state.claimSent) return;

    try {
      await ref.read(tradeRepositoryProvider).claimManualPayment(trade.id);
      state = state.copyWith(claimSent: true, clearActionError: true);
      unawaited(_poll());
    } on ApiException catch (e) {
      state = state.copyWith(
        actionErrorKey: e.messageKey,
        actionErrorCode: e.code,
      );
    }
  }

  /// Cancels the trade. Returns true when the flow was ended (so the screen
  /// may leave); false when the server refused (for example it was already
  /// paid), in which case the payment keeps being watched.
  Future<bool> cancel() async {
    final trade = state.trade;
    if (trade == null) {
      reset();
      ref.read(tradeProvider.notifier).reset();
      return true;
    }

    try {
      await ref
          .read(tradeRepositoryProvider)
          .cancelTrade(trade.id,
              idempotencyKey: ref.read(attemptKeyGeneratorProvider)(),
              config: ref.read(appConfigProvider).config);
      reset();
      ref.read(tradeProvider.notifier).reset();
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(
        actionErrorKey: e.messageKey,
        actionErrorCode: e.code,
      );
      return false;
    }
  }

  void reset() {
    _stopTimers();
    _generation++;
    state = const PaymentState();
  }
}

final paymentProvider =
    NotifierProvider<PaymentNotifier, PaymentState>(PaymentNotifier.new);
