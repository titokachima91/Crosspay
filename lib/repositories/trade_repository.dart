import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/quote_model.dart';

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
      final route = switch (root.string('route')) {
        'p2p' => RouteType.p2p,
        'bank' => RouteType.bank,
        _ => throw ApiException.invalidResponse('route'),
      };
      return Estimate(
        rate: root.number('rate'),
        receiveAmountMinor: root.integer('receiveAmountMinor'),
        estimatedMinSeconds: root.integer('estimatedMinSeconds'),
        estimatedMaxSeconds: root.integer('estimatedMaxSeconds'),
        route: route,
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final tradeRepositoryProvider = Provider<TradeRepository>(
  (ref) => TradeRepository(ref.watch(dioProvider)),
);
