import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/idempotency_interceptor.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/repositories/status_parser.dart';

/// Trading calls. See docs/api_contract.md.
class TradeRepository {
  TradeRepository(this._dio);

  final Dio _dio;

  /// An indicative conversion for the amount being typed. The server
  /// calculates it; the app only displays it.
  Future<Estimate> estimate({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        ApiEndpoints.tradeEstimate,
        queryParameters: {
          'sendCurrency': sendCurrency.code,
          'receiveCurrency': receiveCurrency.code,
          'sendAmountMinor': sendAmountMinor,
        },
      );
      final root = JsonReader.of(response.data);
      return Estimate(
        rate: root.number('rate'),
        receiveAmountMinor: root.integer('receiveAmountMinor'),
        estimatedMinSeconds: root.integer('estimatedMinSeconds'),
        estimatedMaxSeconds: root.integer('estimatedMaxSeconds'),
        route: _routeType(root.string('route')),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// A priced, time-limited quote with the available routes. The lock ends
  /// at the time the server says; nothing here assumes how long it lasts.
  Future<Quote> quote({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.tradeQuote,
        data: {
          'sendCurrency': sendCurrency.code,
          'receiveCurrency': receiveCurrency.code,
          'sendAmountMinor': sendAmountMinor,
        },
      );
      final receivedAt = DateTime.now();
      final root = JsonReader.of(response.data);

      final serverTime = _time(root, 'serverTime');
      return Quote(
        id: root.string('id'),
        sendCurrency: sendCurrency,
        receiveCurrency: receiveCurrency,
        sendAmountMinor: sendAmountMinor,
        rate: root.number('rate'),
        expiresAt: _time(root, 'expiresAt'),
        clockOffset: serverTime.difference(receivedAt),
        routes: [for (final item in root.list('routes')) _parseRoute(item)],
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Starts the payment for an authorized recipient. [idempotencyKey] is the
  /// ONE key for this authorization attempt: the server must return the same
  /// result for a repeated key and never collect twice.
  Future<InitiatedTrade> initiate({
    required Quote quote,
    required RouteType route,
    required RecipientDetails recipient,
    required String idempotencyKey,
    required AppConfig config,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.tradeInitiate,
        data: {
          'quoteId': quote.id,
          'route': route.name,
          'recipient': {
            'railId': recipient.rail.id,
            'account': recipient.account,
            'name': recipient.name,
            if (recipient.reference.isNotEmpty) 'reference': recipient.reference,
          },
        },
        options: Options(extra: {IdempotencyInterceptor.extraKey: idempotencyKey}),
      );
      final root = JsonReader.of(response.data);
      final trade = _parseTrade(root.object('trade'), config);

      final c = root.object('collection');
      final manual = c.optionalObject('manual');
      return InitiatedTrade(
        trade: trade,
        collection: CollectionInstructions(
          pushSent: c.boolean('pushSent'),
          networkName: c.optionalString('networkName'),
          amountMinor: c.integer('amountMinor'),
          currency: quote.sendCurrency,
          pushTimeoutSeconds: c.integer('pushTimeoutSeconds'),
          pollIntervalSeconds: c.integer('pollIntervalSeconds'),
          manual: manual == null
              ? null
              : ManualPayment(
                  methodCode: manual.string('methodCode'),
                  number: manual.string('number'),
                  reference: manual.string('reference'),
                ),
        ),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// The current state of a trade. The SERVER decides when the deposit has
  /// arrived; the app only reads the status.
  Future<Trade> fetchTrade(String id, AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.trade(id));
      return _parseTrade(JsonReader.of(response.data), config);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// "I have completed the manual payment": asks the server to re-check
  /// now. It confirms nothing by itself.
  Future<void> claimManualPayment(String tradeId) async {
    try {
      await _dio.post<dynamic>(ApiEndpoints.tradePaymentClaim(tradeId));
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<Trade> getTrade(String tradeId, AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.trade(tradeId));
      final root = JsonReader.of(response.data);
      return _parseTrade(root, config);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Fetch the signed-in user's trade history (newest first).
  /// Server returns `{ "trades": [ ... ] }`. Until the backend ships
  /// GET /trades the call fails and the UI says so plainly ("not connected").
  Future<List<Trade>> getTrades(AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.trades);
      final root = JsonReader.of(response.data);
      final items = root.list('trades');
      return items.map((e) => _parseTrade(JsonReader.of(e), config)).toList();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Claim manual payment for a trade
  /// [idempotencyKey] is the ONE key for this authorization attempt: the server
  /// must return the same result for a repeated key and never collect twice.
  Future<void> claimPayment(String tradeId, {required String idempotencyKey}) async {
    try {
      await _dio.post<dynamic>(ApiEndpoints.tradePaymentClaim(tradeId),
        data: {'idempotencyKey': idempotencyKey},
      );
      // Server response handled by trade status stream
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Cancel a trade
  Future<Trade> cancelTrade(String tradeId, {required String idempotencyKey, required AppConfig config}) async {
    try {
      final response = await _dio.post<dynamic>(ApiEndpoints.tradeCancel(tradeId),
        data: {'idempotencyKey': idempotencyKey},
      );
      return _parseTrade(JsonReader.of(response.data), config);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  static RouteType _routeType(String value) => switch (value) {
        'p2p' => RouteType.p2p,
        'bank' => RouteType.bank,
        _ => throw ApiException.invalidResponse('route'),
      };

  static DateTime _time(JsonReader root, String key) {
    final text = root.string(key);
    try {
      return DateTime.parse(text);
    } on FormatException {
      throw ApiException.invalidResponse(key);
    }
  }

  static RouteQuote _parseRoute(JsonReader item) {
    return RouteQuote(
      route: _routeType(item.string('route')),
      feeBps: item.integer('feeBps'),
      feeMinor: item.integer('feeMinor'),
      payoutMinor: item.integer('payoutMinor'),
      totalDebitMinor: item.integer('totalDebitMinor'),
      estimatedMinSeconds: item.integer('estimatedMinSeconds'),
      estimatedMaxSeconds: item.integer('estimatedMaxSeconds'),
      isRecommended: item.boolean('isRecommended'),
      isAvailable: item.boolean('isAvailable'),
      matchingDensityPercent: item.optionalInt('matchingDensityPercent'),
      status: parseCorridorStatus(item.optionalObject('status')),
      safeguardCode: item.optionalString('safeguardCode'),
      breakdown: [
        for (final line in item.list('breakdown'))
          FeeLine(
            code: line.string('code'),
            amountMinor: line.integer('amountMinor'),
          ),
      ],
    );
  }

  /// Generates a shareable invoice with QR code for the trade.
  Future<Invoice> getInvoice(String tradeId, {required AppConfig config}) async {
    try {
      final response = await _dio.get<dynamic>(
        ApiEndpoints.tradeInvoice(tradeId),
      );
      final root = JsonReader.of(response.data);
      return Invoice(
        tradeId: root.string('tradeId'),
        qrCodeUrl: root.string('qrCodeUrl'),
        shareUrl: root.string('shareUrl'),
        validUntil: _time(root, 'validUntil'),
        amount: root.integer('amount'),
        currency: root.string('currency'),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Creates a shareable invoice link for the trade.
  Future<void> shareTrade(String tradeId, {required String idempotencyKey, required AppConfig config}) async {
    try {
      await _dio.post<dynamic>(
        ApiEndpoints.tradeShare(tradeId),
        data: {'idempotencyKey': idempotencyKey},
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  static Trade _parseTrade(JsonReader json, AppConfig config) {
    Currency currency(String key) {
      final found = config.currencyByCode(json.string(key));
      if (found == null) throw ApiException.invalidResponse(key);
      return found;
    }

    final status = switch (json.string('status')) {
      'pending_deposit' => TradeStatus.pendingDeposit,
      'escrowed' => TradeStatus.escrowed,
      'matching' => TradeStatus.matching,
      'matched' => TradeStatus.matched,
      'disbursing' => TradeStatus.disbursing,
      'completed' => TradeStatus.completed,
      'expired' => TradeStatus.expired,
      'refunded' => TradeStatus.refunded,
      'failed' => TradeStatus.failed,
      'cancelled' => TradeStatus.cancelled,
      _ => throw ApiException.invalidResponse('status'),
    };

    return Trade(
      id: json.string('id'),
      reference: json.string('reference'),
      route: _routeType(json.string('route')),
      status: status,
      sendCurrency: currency('sendCurrency'),
      receiveCurrency: currency('receiveCurrency'),
      sendAmountMinor: json.integer('sendAmountMinor'),
      feeMinor: json.integer('feeMinor'),
      feeBps: json.integer('feeBps'),
      receiveAmountMinor: json.integer('receiveAmountMinor'),
      rate: json.number('rate'),
      beneficiaryName: json.string('beneficiaryName'),
      createdAt: _time(json, 'createdAt'),
      verificationHash: json.optionalString('verificationHash'),
    );
  }
}

final tradeRepositoryProvider = Provider<TradeRepository>(
  (ref) => TradeRepository(ref.watch(dioProvider)),
);
