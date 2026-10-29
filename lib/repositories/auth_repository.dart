import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/user_model.dart';

/// Sign-in calls. See docs/api_contract.md.
class AuthRepository {
  AuthRepository(this._dio);

  final Dio _dio;

  /// Asks the server to text a verification code to [phone]
  /// (international format, e.g. "+<calling code><number>").
  Future<OtpChallenge> requestOtp(String phone) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.otpRequest,
        data: {'phone': phone},
      );
      final root = JsonReader.of(response.data);
      return OtpChallenge(
        codeLength: root.integer('codeLength'),
        resendAfterSeconds: root.integer('resendAfterSeconds'),
        expiresInSeconds: root.integer('expiresInSeconds'),
        requestedAt: DateTime.now(),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(dioProvider)),
);
