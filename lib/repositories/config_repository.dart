import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';

/// Fetches the reference data the server controls. See docs/api_contract.md.
class ConfigRepository {
  ConfigRepository(this._dio);

  final Dio _dio;

  Future<AppConfig> fetch() async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.config);
      final root = JsonReader.of(response.data);
      return AppConfig(
        currencies: [
          for (final c in root.list('currencies'))
            Currency(
              code: c.string('code'),
              name: c.string('name'),
              countryCode: c.string('countryCode'),
            ),
        ],
        hubs: [
          for (final h in root.list('hubs'))
            TradingHub(
              id: h.string('id'),
              name: h.string('name'),
              countryCode: h.string('countryCode'),
            ),
        ],
        payoutRails: [
          for (final r in root.list('payoutRails'))
            PayoutRail(
              id: r.string('id'),
              name: r.string('name'),
              countryCode: r.string('countryCode'),
            ),
        ],
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) => ConfigRepository(ref.watch(dioProvider)),
);
