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
      final support = root.optionalObject('support');
      final service = root.optionalObject('service');
      return AppConfig(
        support: support == null
            ? null
            : SupportInfo(
                email: support.optionalString('email'),
                phone: support.optionalString('phone'),
                whatsapp: support.optionalString('whatsapp'),
                hours: support.optionalString('hours'),
              ),
        service: service == null
            ? null
            : ServiceStatus(
                quotesPaused: service.boolean('quotesPaused'),
                tradesPaused: service.boolean('tradesPaused'),
                message: service.optionalString('message'),
              ),
        banners: [
          for (final b in root.optionalList('banners'))
            AppBanner(
              id: b.string('id'),
              messageEn: b.string('messageEn'),
              messageSw: b.string('messageSw'),
              severity: switch (b.string('severity')) {
                'info' => BannerSeverity.info,
                'warning' => BannerSeverity.warning,
                'critical' => BannerSeverity.critical,
                _ => throw ApiException.invalidResponse('banners.severity'),
              },
              startsAt: _serverTime(b, 'startsAt'),
              endsAt: _serverTime(b, 'endsAt'),
            ),
        ],
        currencies: [
          for (final c in root.list('currencies'))
            Currency(
              code: c.string('code'),
              name: c.string('name'),
              countryCode: c.string('countryCode'),
              decimals: c.integer('decimals'),
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
              kind: switch (r.string('kind')) {
                'mobile_money' => PayoutKind.mobileMoney,
                'bank' => PayoutKind.bank,
                _ => throw ApiException.invalidResponse('payoutRails.kind'),
              },
            ),
        ],
        countries: [
          for (final c in root.list('countries'))
            Country(
              code: c.string('code'),
              name: c.string('name'),
              // Tolerate "+255" as well as "255".
              dialCode: c.string('dialCode').replaceAll(RegExp(r'\D'), ''),
              nationalNumberLength: c.integer('nationalNumberLength'),
            ),
        ],
        carriers: [
          for (final c in root.list('carriers'))
            Carrier(
              id: c.string('id'),
              name: c.string('name'),
              countryCode: c.string('countryCode'),
              prefixPattern: c.string('prefixPattern'),
            ),
        ],
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Dates in `/config` are ISO-8601 from the server. Compare them as UTC; the
/// screen decides how to display local time.
DateTime _serverTime(JsonReader json, String key) {
  final raw = json.string(key);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw ApiException.invalidResponse(key);
  return parsed.toUtc();
}

final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) => ConfigRepository(ref.watch(dioProvider)),
);
