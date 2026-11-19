import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum TradeFlowStatus { idle, submitting, active, error }

/// Creates the unique key for one authorization attempt. Replaced in tests.
final attemptKeyGeneratorProvider = Provider<String Function()>(
  (ref) => () => const Uuid().v4(),
);

class TradeState {
  const TradeState({
    this.flowStatus = TradeFlowStatus.idle,
    this.beneficiary,
    this.recipient,
    this.attemptKey,
    this.attemptQuoteId,
    this.activeTrade,
    this.invoice,
    this.invoiceLoading = false,
    this.invoiceErrorKey,
    this.errorMessage,
  });

  final TradeFlowStatus flowStatus;

  /// A saved recipient tapped on Home (used to prefill Screen 2.3).
  final Beneficiary? beneficiary;

  /// The recipient details the person authorized paying.
  final RecipientDetails? recipient;

  /// ONE key per authorization attempt. The payment step sends it with every
  /// request about this attempt, so a double tap, a lost connection or a
  /// reopened screen can never charge twice.
  final String? attemptKey;
  final String? attemptQuoteId;

  /// The trade being tracked on Screens 2.4 to 2.6.
  final Trade? activeTrade;

  /// The server-issued invoice for [activeTrade], once loaded.
  final Invoice? invoice;
  final bool invoiceLoading;

  /// Localization key for the last invoice failure.
  final String? invoiceErrorKey;
  final String? errorMessage;

  TradeState copyWith({
    TradeFlowStatus? flowStatus,
    Beneficiary? beneficiary,
    RecipientDetails? recipient,
    String? attemptKey,
    String? attemptQuoteId,
    Trade? activeTrade,
    Invoice? invoice,
    bool clearInvoice = false,
    bool? invoiceLoading,
    String? invoiceErrorKey,
    bool clearInvoiceError = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TradeState(
      flowStatus: flowStatus ?? this.flowStatus,
      beneficiary: beneficiary ?? this.beneficiary,
      recipient: recipient ?? this.recipient,
      attemptKey: attemptKey ?? this.attemptKey,
      attemptQuoteId: attemptQuoteId ?? this.attemptQuoteId,
      activeTrade: activeTrade ?? this.activeTrade,
      invoice: clearInvoice ? null : (invoice ?? this.invoice),
      invoiceLoading: invoiceLoading ?? this.invoiceLoading,
      invoiceErrorKey:
          clearInvoiceError ? null : (invoiceErrorKey ?? this.invoiceErrorKey),
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

  /// Called when the person taps Authorize. The same recipient details on the
  /// same quote keep the same key (going back and forth must not create a
  /// second payment); anything different is a new attempt with a new key.
  void authorize(RecipientDetails details, {required String quoteId}) {
    final current = state.recipient;
    final sameAttempt = current != null &&
        current.sameAs(details) &&
        state.attemptQuoteId == quoteId &&
        state.attemptKey != null;

    state = state.copyWith(
      recipient: details,
      attemptKey: sameAttempt
          ? state.attemptKey
          : ref.read(attemptKeyGeneratorProvider)(),
      attemptQuoteId: quoteId,
      clearError: true,
    );
  }

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
  void tradeUpdated(Trade trade) => state = state.copyWith(activeTrade: trade);

  void failed(String message) => state = state.copyWith(
        flowStatus: TradeFlowStatus.error,
        errorMessage: message,
      );

  /// Load a trade by ID from the server
  Future<void> loadTrade(String tradeId) async {
    final repo = ref.read(tradeRepositoryProvider);
    final config = ref.read(appConfigProvider).config;
    final trade = await repo.getTrade(tradeId, config);
    state = state.copyWith(
      activeTrade: trade,
      flowStatus: TradeFlowStatus.active,
      clearInvoice: true,
      clearInvoiceError: true,
    );
  }

  /// Claim manual payment for the active trade
  /// Uses idempotency key to prevent double collection
  Future<void> claimManualPayment({required String idempotencyKey}) async {
    final repo = ref.read(tradeRepositoryProvider);
    final appConfig = ref.read(appConfigProvider).config;
    await repo.claimPayment(state.activeTrade!.id,
        idempotencyKey: idempotencyKey);
    // Trigger a fetch to get updated state
    await repo.getTrade(state.activeTrade!.id, appConfig);
    state = state.copyWith(clearError: true);
  }

  /// Reset trade tracking state
  void resetTradeTracking() => state = const TradeState(
        flowStatus: TradeFlowStatus.idle,
        activeTrade: null,
      );

  /// Ask the server for this trade's invoice link. The server decides the
  /// token, expiry and URLs; a second call returns the same link.
  Future<void> loadInvoice(String tradeId) async {
    final config = ref.read(appConfigProvider).config;
    state = state.copyWith(invoiceLoading: true, clearInvoiceError: true);
    try {
      final invoice = await ref
          .read(tradeRepositoryProvider)
          .getInvoice(tradeId, config: config);
      state = state.copyWith(invoice: invoice, invoiceLoading: false);
    } on ApiException catch (error) {
      state = state.copyWith(
        invoiceLoading: false,
        clearInvoice: true,
        invoiceErrorKey: _invoiceErrorKey(error),
      );
    }
  }

  static String _invoiceErrorKey(ApiException error) => switch (error.code) {
        'INVOICE_EXPIRED' => 'invoice.error.expired',
        'INVOICE_NOT_AVAILABLE' => 'invoice.error.not_available',
        'INVOICE_NOT_CONFIGURED' => 'invoice.error.not_configured',
        _ => error.messageKey,
      };

  void reset() => state = const TradeState();
}

final tradeProvider =
    NotifierProvider<TradeNotifier, TradeState>(TradeNotifier.new);
