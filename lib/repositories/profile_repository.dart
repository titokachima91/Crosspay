import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/user_model.dart';

/// The signed-in person's profile. See docs/api_contract.md.
class ProfileRepository {
  ProfileRepository(this._dio);

  final Dio _dio;

  /// Needs the server config to turn codes (currency, market) into objects.
  Future<UserProfile> fetch(AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.me);
      final root = JsonReader.of(response.data);

      final limit = root.object('limit');
      final limitCurrency = config.currencyByCode(limit.string('currency'));
      if (limitCurrency == null) {
        throw ApiException.invalidResponse('limit.currency');
      }

      final accountType = switch (root.string('accountType')) {
        'personal' => AccountType.personal,
        'business' => AccountType.business,
        _ => throw ApiException.invalidResponse('accountType'),
      };
      final kycStatus = switch (root.string('kycStatus')) {
        'verified' => KycStatus.verified,
        'pending' => KycStatus.pending,
        'rejected' => KycStatus.rejected,
        _ => throw ApiException.invalidResponse('kycStatus'),
      };

      final hubId = root.optionalString('hubId');
      TradingHub? hub;
      if (hubId != null) {
        for (final h in config.hubs) {
          if (h.id == hubId) hub = h;
        }
      }

      return UserProfile(
        id: root.string('id'),
        phone: root.string('phone'),
        displayName: root.string('displayName'),
        accountType: accountType,
        hub: hub,
        kycStatus: kycStatus,
        limitCurrency: limitCurrency,
        dailyLimitMinor: limit.integer('dailyLimitMinor'),
        dailyUsedMinor: limit.integer('dailyUsedMinor'),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(dioProvider)),
);
