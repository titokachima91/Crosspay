import 'package:dio/dio.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const fakeSend =
    Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const fakeReceive =
    Currency(code: 'BBB', name: 'Beta', countryCode: 'YY', decimals: 2);

const fakeRail = PayoutRail(
  id: 'r1',
  name: 'Test Rail',
  countryCode: 'YY',
  kind: PayoutKind.mobileMoney,
);

Quote fakeQuote() => Quote(
      id: 'q1',
      sendCurrency: fakeSend,
      receiveCurrency: fakeReceive,
      sendAmountMinor: 1000,
      rate: 2,
      expiresAt: DateTime.now().add(const Duration(seconds: 300)),
      routes: const [
        RouteQuote(
          route: RouteType.p2p,
          feeBps: 150,
          feeMinor: 15,
          payoutMinor: 50000,
          totalDebitMinor: 1015,
          estimatedMinSeconds: 1800,
          estimatedMaxSeconds: 7200,
          isRecommended: true,
          isAvailable: true,
        ),
      ],
    );

RecipientDetails fakeRecipient({String reference = ''}) => RecipientDetails(
      rail: fakeRail,
      account: '+888712345678',
      name: 'Test Person',
      reference: reference,
      check: const RecipientCheck(accountStatus: AccountStatus.found),
    );

Trade fakeTrade(TradeStatus status) => Trade(
      id: 't1',
      reference: 'REF-1',
      route: RouteType.p2p,
      status: status,
      sendCurrency: fakeSend,
      receiveCurrency: fakeReceive,
      sendAmountMinor: 1000,
      feeMinor: 15,
      feeBps: 150,
      receiveAmountMinor: 50000,
      rate: 2,
      beneficiaryName: 'Test Person',
      createdAt: DateTime(2026, 1, 1),
    );

CollectionInstructions fakeCollection({bool pushSent = true}) =>
    CollectionInstructions(
      pushSent: pushSent,
      networkName: 'Test Network',
      amountMinor: 1015,
      currency: fakeSend,
      pushTimeoutSeconds: 30,
      pollIntervalSeconds: 2,
      manual: const ManualPayment(
        methodCode: 'paybill',
        number: '123456',
        reference: 'REF-1',
      ),
    );

InitiatedTrade fakeInitiated({
  TradeStatus status = TradeStatus.pendingDeposit,
  bool pushSent = true,
}) =>
    InitiatedTrade(
      trade: fakeTrade(status),
      collection: fakeCollection(pushSent: pushSent),
    );

class FakeTradeRepository extends TradeRepository {
  FakeTradeRepository({
    this.onInitiate,
    this.onFetch,
    this.onClaim,
    this.onCancel,
  }) : super(Dio());

  final Future<InitiatedTrade> Function()? onInitiate;
  final Future<Trade> Function()? onFetch;
  final Future<void> Function()? onClaim;
  final Future<Trade> Function()? onCancel;

  int initiateCalls = 0;
  int fetchCalls = 0;
  int claimCalls = 0;
  int cancelCalls = 0;
  String? lastKey;
  String? lastQuoteId;
  RouteType? lastRoute;
  RecipientDetails? lastRecipient;

  @override
  Future<InitiatedTrade> initiate({
    required Quote quote,
    required RouteType route,
    required RecipientDetails recipient,
    required String idempotencyKey,
    required AppConfig config,
  }) {
    initiateCalls++;
    lastKey = idempotencyKey;
    lastQuoteId = quote.id;
    lastRoute = route;
    lastRecipient = recipient;
    return onInitiate!();
  }

  @override
  Future<Trade> fetchTrade(String id, AppConfig config) {
    fetchCalls++;
    return onFetch!();
  }

  @override
  Future<void> claimManualPayment(String tradeId) {
    claimCalls++;
    return onClaim?.call() ?? Future<void>.value();
  }

  @override
  Future<Trade> cancelTrade(String tradeId, {required String idempotencyKey, required AppConfig config}) {
    cancelCalls++;
    return onCancel!();
  }
}
