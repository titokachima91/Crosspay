import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/repositories/status_parser.dart';

class RatesSnapshot {
  const RatesSnapshot({
    required this.rates,
    this.p2pDensityPercent,
    this.bankSweepPercent,
  });

  final List<CorridorRate> rates;
  final int? p2pDensityPercent;
  final int? bankSweepPercent;
}

/// Fetches live corridor rates. See docs/api_contract.md.
class RatesRepository {
  RatesRepository(this._dio);

  final Dio _dio;

  /// Currency codes are matched against [config]. A rate that mentions a
  /// currency the config does not list is skipped.
  Future<RatesSnapshot> fetch(AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.rates);
      final root = JsonReader.of(response.data);

      final rates = <CorridorRate>[];
      for (final item in root.list('rates')) {
        final from = config.currencyByCode(item.string('from'));
        final to = config.currencyByCode(item.string('to'));
        if (from == null || to == null) continue;
        rates.add(
          CorridorRate(
            from: from,
            to: to,
            rate: item.number('rate'),
            change24hPercent: item.optionalNumber('change24hPercent'),
            status: parseCorridorStatus(item.optionalObject('status')),
          ),
        );
      }

      final health = root.optionalObject('queueHealth');
      return RatesSnapshot(
        rates: rates,
        p2pDensityPercent: health?.optionalInt('p2pDensityPercent'),
        bankSweepPercent: health?.optionalInt('bankSweepPercent'),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final ratesRepositoryProvider = Provider<RatesRepository>(
  (ref) => RatesRepository(ref.watch(dioProvider)),
);
