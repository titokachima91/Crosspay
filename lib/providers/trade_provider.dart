import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';

enum TradeFlowStatus { idle, submitting, active, error }

class TradeState {
  const TradeState({
    this.flowStatus = TradeFlowStatus.idle,
    this.beneficiary,
    this.paymentReference = '',
    this.activeTrade,
    this.errorMessage,
  });

  final TradeFlowStatus flowStatus;

  /// Chosen on Screen 2.3.
  final Beneficiary? beneficiary;

  /// Optional invoice note from Screen 2.3.
  final String paymentReference;

  /// The trade being tracked on Screens 2.4 to 2.6.
  final Trade? activeTrade;
  final String? errorMessage;

  TradeState copyWith({
    TradeFlowStatus? flowStatus,
    Beneficiary? beneficiary,
    String? paymentReference,
    Trade? activeTrade,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TradeState(
      flowStatus: flowStatus ?? this.flowStatus,
      beneficiary: beneficiary ?? this.beneficiary,
      paymentReference: paymentReference ?? this.paymentReference,
      activeTrade: activeTrade ?? this.activeTrade,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class TradeNotifier extends Notifier<TradeState> {
  @override
  TradeState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        reset();
      }
    });
    return const TradeState();
  }

  void selectBeneficiary(Beneficiary b) =>
      state = state.copyWith(beneficiary: b, clearError: true);

  void setPaymentReference(String text) =>
      state = state.copyWith(paymentReference: text);

  void submitting() => state = state.copyWith(
        flowStatus: TradeFlowStatus.submitting,
        clearError: true,
      );

  void tradeStarted(Trade trade) => state = state.copyWith(
        flowStatus: TradeFlowStatus.active,
        activeTrade: trade,
        clearError: true,
      );

  /// Call for each live update from the order tracker.
  void tradeUpdated(Trade trade) =>
      state = state.copyWith(activeTrade: trade);

  void failed(String message) => state = state.copyWith(
        flowStatus: TradeFlowStatus.error,
        errorMessage: message,
      );

  void reset() => state = const TradeState();
}

final tradeProvider =
    NotifierProvider<TradeNotifier, TradeState>(TradeNotifier.new);
