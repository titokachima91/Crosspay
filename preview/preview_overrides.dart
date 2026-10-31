// SIMULATED DATA LIVES HERE AND ONLY HERE.
// The real app (lib/) never imports this folder; a test enforces that.
// Deleting the preview/ folder removes every simulated value.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

/// The only SMS code the preview accepts.
const String previewOtpCode = '1234';

const Currency _tzs =
    Currency(code: 'TZS', name: 'Tanzanian Shilling', countryCode: 'TZ');
const Currency _kes =
    Currency(code: 'KES', name: 'Kenyan Shilling', countryCode: 'KE');

const AppConfig previewConfig = AppConfig(
  currencies: [_tzs, _kes],
  hubs: [
    TradingHub(id: 'hub-1', name: 'Kariakoo, Dar es Salaam', countryCode: 'TZ'),
    TradingHub(id: 'hub-2', name: 'Eastleigh, Nairobi', countryCode: 'KE'),
  ],
  payoutRails: [
    PayoutRail(id: 'rail-1', name: 'Preview mobile money A', countryCode: 'KE'),
    PayoutRail(id: 'rail-2', name: 'Preview mobile money B', countryCode: 'TZ'),
  ],
  countries: [
    Country(
      code: 'TZ',
      name: 'Tanzania',
      dialCode: '255',
      nationalNumberLength: 9,
    ),
    Country(
      code: 'KE',
      name: 'Kenya',
      dialCode: '254',
      nationalNumberLength: 9,
    ),
  ],
  // Made-up networks and prefixes. Not real telecom data.
  carriers: [
    Carrier(
      id: 'tz-a',
      name: 'Preview Network A (Tanzania)',
      countryCode: 'TZ',
      prefixPattern: '^7[1-4]',
    ),
    Carrier(
      id: 'tz-b',
      name: 'Preview Network B (Tanzania)',
      countryCode: 'TZ',
      prefixPattern: '^7[5-9]',
    ),
    Carrier(
      id: 'ke-a',
      name: 'Preview Network A (Kenya)',
      countryCode: 'KE',
      prefixPattern: '^7[0-4]',
    ),
    Carrier(
      id: 'ke-b',
      name: 'Preview Network B (Kenya)',
      countryCode: 'KE',
      prefixPattern: '^7[5-9]',
    ),
  ],
);

Future<void> _wait(Duration latency) async {
  if (latency > Duration.zero) {
    await Future<void>.delayed(latency);
  }
}

class _PreviewConfigRepository extends ConfigRepository {
  _PreviewConfigRepository(this._latency) : super(Dio());

  final Duration _latency;

  @override
  Future<AppConfig> fetch() async {
    await _wait(_latency);
    return previewConfig;
  }
}

class _PreviewRatesRepository extends RatesRepository {
  _PreviewRatesRepository(this._latency) : super(Dio());

  final Duration _latency;

  @override
  Future<RatesSnapshot> fetch(AppConfig config) async {
    await _wait(_latency);
    return const RatesSnapshot(
      rates: [
        CorridorRate(
          from: _tzs,
          to: _kes,
          rate: 19.85,
          change24hPercent: 0.4,
          status: CorridorStatus(
            code: 'balanced_p2p',
            level: CorridorLevel.healthy,
          ),
        ),
        CorridorRate(
          from: _kes,
          to: _tzs,
          rate: 0.0504,
          change24hPercent: -0.4,
          status: CorridorStatus(
            code: 'high_liquidity',
            level: CorridorLevel.healthy,
          ),
        ),
      ],
      p2pDensityPercent: 72,
      bankSweepPercent: 88,
    );
  }
}

class _PreviewAuthRepository extends AuthRepository {
  _PreviewAuthRepository(this._latency) : super(Dio());

  final Duration _latency;

  @override
  Future<OtpChallenge> requestOtp(String phone) async {
    await _wait(_latency);
    return OtpChallenge(
      codeLength: previewOtpCode.length,
      resendAfterSeconds: 30,
      expiresInSeconds: 300,
      requestedAt: DateTime.now(),
    );
  }

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    await _wait(_latency);
    if (code != previewOtpCode) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 400,
        code: 'OTP_INVALID',
      );
    }
    return const AuthSession(
      accessToken: 'preview-token',
      profileComplete: false,
    );
  }

  /// An ID containing "bad" is rejected; one containing "wait" stays pending;
  /// anything else is verified.
  @override
  Future<KycStatus> submitKyc({
    required AccountType accountType,
    required String legalName,
    String? hubId,
    required String idNumber,
  }) async {
    await _wait(_latency);
    final id = idNumber.toLowerCase();
    if (id.contains('bad')) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 422,
        code: 'ID_NUMBER_INVALID',
      );
    }
    return id.contains('wait') ? KycStatus.pending : KycStatus.verified;
  }
}

class _PreviewTokenStorage implements TokenStorage {
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> delete() async => _token = null;
}

/// Everything the preview swaps in. Pass Duration.zero in tests.
List<Override> previewOverrides({
  Duration latency = const Duration(milliseconds: 600),
}) {
  return [
    configRepositoryProvider.overrideWithValue(_PreviewConfigRepository(latency)),
    ratesRepositoryProvider.overrideWithValue(_PreviewRatesRepository(latency)),
    authRepositoryProvider.overrideWithValue(_PreviewAuthRepository(latency)),
    tokenStorageProvider.overrideWithValue(_PreviewTokenStorage()),
  ];
}
