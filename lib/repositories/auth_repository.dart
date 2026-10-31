import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/api_endpoints.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/user_model.dart';

/// Sign-in and onboarding calls. See docs/api_contract.md.
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

  /// Checks the code. On success the server returns the sign-in token.
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        ApiEndpoints.otpVerify,
        data: {'phone': phone, 'code': code},
      );
      final root = JsonReader.of(response.data);
      return AuthSession(
        accessToken: root.string('accessToken'),
        profileComplete: root.boolean('profileComplete'),
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Sends the identity details for verification. [idNumber] is sensitive:
  /// it goes to the server and nowhere else. Never store or log it.
  /// [hubId] is for business accounts only.
  Future<KycStatus> submitKyc({
    required AccountType accountType,
    required String legalName,
    String? hubId,
    required String idNumber,
  }) async {
    try {
      final response = await _dio.put<dynamic>(
        ApiEndpoints.kyc,
        data: {
          'accountType': accountType.name,
          'legalName': legalName,
          if (hubId != null) 'hubId': hubId,
          'idNumber': idNumber,
        },
      );
      final root = JsonReader.of(response.data);
      return switch (root.string('kycStatus')) {
        'verified' => KycStatus.verified,
        'pending' => KycStatus.pending,
        _ => throw const ApiException(
            kind: ApiErrorKind.unknown,
            code: 'INVALID_RESPONSE',
            serverMessage: 'Unexpected format: kycStatus',
          ),
      };
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(dioProvider)),
);
