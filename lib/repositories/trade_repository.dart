import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/quote_model.dart';
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
}

final tradeRepositoryProvider = Provider<TradeRepository>(
  (ref) => TradeRepository(ref.watch(dioProvider)),
);
