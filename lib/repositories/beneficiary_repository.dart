import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';

/// Recipients. See docs/api_contract.md.
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

  /// F5.2 — saves a new recipient (`POST /beneficiaries`). The server returns
  /// the saved record, so the app shows exactly what was stored.
  Future<Beneficiary> add({
    required AppConfig config,
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.beneficiaries,
        data: {
          'railId': rail.id,
          'name': name,
          'accountOrPhone': accountOrPhone,
        },
      );
      return _parseOne(JsonReader.of(response.data), config);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// F5.2 — edits a saved recipient (`PATCH /beneficiaries/{id}`).
  Future<Beneficiary> update({
    required AppConfig config,
    required String id,
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) async {
    try {
      final response = await _dio.patch<dynamic>(
        ApiEndpoints.beneficiary(id),
        data: {
          'railId': rail.id,
          'name': name,
          'accountOrPhone': accountOrPhone,
        },
      );
      return _parseOne(JsonReader.of(response.data), config);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// F5.2 — removes a saved recipient (`DELETE /beneficiaries/{id}`).
  /// A 204 with no body is the expected answer.
  Future<void> remove(String id) async {
    try {
      await _dio.delete<dynamic>(ApiEndpoints.beneficiary(id));
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// One recipient, as the server returned it. A rail the config does not
  /// list means the response is broken: nothing is guessed.
  static Beneficiary _parseOne(JsonReader json, AppConfig config) {
    final railId = json.string('railId');
    PayoutRail? rail;
    for (final r in config.payoutRails) {
      if (r.id == railId) rail = r;
    }
    if (rail == null) throw ApiException.invalidResponse('railId');

    return Beneficiary(
      id: json.string('id'),
      name: json.string('name'),
      rail: rail,
      accountOrPhone: json.string('accountOrPhone'),
      kycVerified: json.boolean('kycVerified'),
    );
  }

  /// Asks the destination network about an account and, when [name] is given,
  /// whether it matches. The answer is only "match" or not: the registered
  /// name is never returned. The account and name go in the body, never in
  /// the address, and must never be logged.
  Future<RecipientCheck> check({
    required PayoutRail rail,
    required String account,
    String? name,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.beneficiaryCheck,
        data: {
          'railId': rail.id,
          'account': account,
          if (name != null) 'name': name,
        },
      );
      final root = JsonReader.of(response.data);

      final accountStatus = switch (root.string('accountStatus')) {
        'found' => AccountStatus.found,
        'not_found' => AccountStatus.notFound,
        _ => throw ApiException.invalidResponse('accountStatus'),
      };
      final matchText = root.optionalString('nameMatch');
      final NameMatch? nameMatch = matchText == null
          ? null
          : switch (matchText) {
              'match' => NameMatch.match,
              'mismatch' => NameMatch.mismatch,
              'unavailable' => NameMatch.unavailable,
              _ => throw ApiException.invalidResponse('nameMatch'),
            };

      return RecipientCheck(
        accountStatus: accountStatus,
        networkName: root.optionalString('networkName'),
        nameMatch: nameMatch,
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final beneficiaryRepositoryProvider = Provider<BeneficiaryRepository>(
  (ref) => BeneficiaryRepository(ref.watch(dioProvider)),
);
