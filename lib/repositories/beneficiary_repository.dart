import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';

/// Saved recipients. See docs/api_contract.md.
class BeneficiaryRepository {
  BeneficiaryRepository(this._dio);

  final Dio _dio;

  /// A recipient whose payout rail is not in the config is skipped.
  Future<List<Beneficiary>> list(AppConfig config) async {
    try {
      final response = await _dio.get<dynamic>(ApiEndpoints.beneficiaries);
      final root = JsonReader.of(response.data);

      final result = <Beneficiary>[];
      for (final item in root.list('beneficiaries')) {
        final railId = item.string('railId');
        PayoutRail? rail;
        for (final r in config.payoutRails) {
          if (r.id == railId) rail = r;
        }
        if (rail == null) continue;

        result.add(
          Beneficiary(
            id: item.string('id'),
            name: item.string('name'),
            rail: rail,
            accountOrPhone: item.string('accountOrPhone'),
            kycVerified: item.boolean('kycVerified'),
          ),
        );
      }
      return result;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final beneficiaryRepositoryProvider = Provider<BeneficiaryRepository>(
  (ref) => BeneficiaryRepository(ref.watch(dioProvider)),
);
