// SIMULATED DATA LIVES HERE AND ONLY HERE.
// The real app (lib/) never imports this folder; a test enforces that.
// Deleting the preview/ folder removes every simulated value.

import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

/// The only SMS code the preview accepts.
const String previewOtpCode = '1234';

const Currency _tzs = Currency(
  code: 'TZS',
  name: 'Tanzanian Shilling',
  countryCode: 'TZ',
  decimals: 0,
);
const Currency _kes = Currency(
  code: 'KES',
  name: 'Kenyan Shilling',
  countryCode: 'KE',
  decimals: 2,
);

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

/// What the preview "remembers" about the person who just registered.
class _PreviewSession {
  String displayName = 'Preview User';
  AccountType accountType = AccountType.personal;
  KycStatus kycStatus = KycStatus.verified;
}

double? _previewRate(String from, String to) {
  if (from == 'TZS' && to == 'KES') return 19.85;
  if (from == 'KES' && to == 'TZS') return 0.0504;
  return null;
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
  _PreviewAuthRepository(this._latency, this._session) : super(Dio());

  final Duration _latency;
  final _PreviewSession _session;

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
    _session
      ..displayName = legalName
      ..accountType = accountType
      ..kycStatus = id.contains('wait') ? KycStatus.pending : KycStatus.verified;
    return _session.kycStatus;
  }
}

class _PreviewProfileRepository extends ProfileRepository {
  _PreviewProfileRepository(this._latency, this._session) : super(Dio());

  final Duration _latency;
  final _PreviewSession _session;

  @override
  Future<UserProfile> fetch(AppConfig config) async {
    await _wait(_latency);
    return UserProfile(
      id: 'preview-user',
      phone: '+255712345678',
      displayName: _session.displayName,
      accountType: _session.accountType,
      hub: _session.accountType == AccountType.business
          ? config.hubs.first
          : null,
      kycStatus: _session.kycStatus,
      limitCurrency: config.currencyByCode('TZS') ?? config.currencies.first,
      dailyLimitMinor: 10000000,
      dailyUsedMinor: 2000000,
    );
  }
}

class _PreviewBeneficiaryRepository extends BeneficiaryRepository {
  _PreviewBeneficiaryRepository(this._latency) : super(Dio());

  final Duration _latency;

  @override
  Future<List<Beneficiary>> list(AppConfig config) async {
    await _wait(_latency);
    if (config.payoutRails.isEmpty) return const [];
    final rail = config.payoutRails.first;
    return [
      Beneficiary(
        id: 'b1',
        name: 'Eastleigh Textiles',
        rail: rail,
        accountOrPhone: '+254700000001',
        kycVerified: true,
      ),
      Beneficiary(
        id: 'b2',
        name: 'Lusaka Import Export',
        rail: rail,
        accountOrPhone: '+254700000002',
        kycVerified: true,
      ),
      Beneficiary(
        id: 'b3',
        name: 'Nairobi Motors',
        rail: rail,
        accountOrPhone: '+254700000003',
      ),
      Beneficiary(
        id: 'b4',
        name: 'Kampala Wholesale',
        rail: rail,
        accountOrPhone: '+254700000004',
        kycVerified: true,
      ),
    ];
  }
}

class _PreviewTradeRepository extends TradeRepository {
  _PreviewTradeRepository(this._latency) : super(Dio());

  final Duration _latency;

  @override
  Future<Estimate> estimate({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) async {
    await _wait(_latency);
    final rate = _previewRate(sendCurrency.code, receiveCurrency.code);
    if (rate == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 400,
        code: 'CORRIDOR_UNAVAILABLE',
      );
    }

    final sendMajor =
        sendAmountMinor / math.pow(10, sendCurrency.decimals).toDouble();
    final receiveMajor = sendMajor / rate;
    final receiveMinor =
        (receiveMajor * math.pow(10, receiveCurrency.decimals)).round();

    return Estimate(
      rate: rate,
      receiveAmountMinor: receiveMinor,
      estimatedMinSeconds: 1800,
      estimatedMaxSeconds: 7200,
      route: RouteType.p2p,
    );
  }

  @override
  Future<Quote> quote({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) async {
    await _wait(_latency);
    final rate = _previewRate(sendCurrency.code, receiveCurrency.code);
    if (rate == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 400,
        code: 'CORRIDOR_UNAVAILABLE',
      );
    }

    final sendMajor =
        sendAmountMinor / math.pow(10, sendCurrency.decimals).toDouble();
    final payout =
        (sendMajor / rate * math.pow(10, receiveCurrency.decimals)).round();
    int part(int bps) => (sendAmountMinor * bps / 10000).round();

    RouteQuote build(
      RouteType type, {
      required int platformBps,
      required int networkBps,
      required int minSeconds,
      required int maxSeconds,
      required bool recommended,
      required bool available,
      required String statusCode,
      required String safeguard,
    }) {
      final platform = part(platformBps);
      final network = part(networkBps);
      return RouteQuote(
        route: type,
        feeBps: platformBps + networkBps,
        feeMinor: platform + network,
        payoutMinor: payout,
        totalDebitMinor: sendAmountMinor + platform + network,
        estimatedMinSeconds: minSeconds,
        estimatedMaxSeconds: maxSeconds,
        isRecommended: recommended,
        isAvailable: available,
        status: available
            ? CorridorStatus(code: statusCode, level: CorridorLevel.healthy)
            : null,
        safeguardCode: safeguard,
        breakdown: [
          FeeLine(code: 'platform_fee', amountMinor: platform),
          FeeLine(code: 'network_fee', amountMinor: network),
        ],
      );
    }

    // Above this amount the simulated bank route becomes unavailable.
    final bankAvailable = sendMajor <= 5000000;

    return Quote(
      id: 'preview-quote',
      sendCurrency: sendCurrency,
      receiveCurrency: receiveCurrency,
      sendAmountMinor: sendAmountMinor,
      rate: rate,
      expiresAt: DateTime.now().add(const Duration(seconds: 90)),
      routes: [
        build(
          RouteType.p2p,
          platformBps: 100,
          networkBps: 50,
          minSeconds: 1800,
          maxSeconds: 7200,
          recommended: true,
          available: true,
          statusCode: 'high_matching_density',
          safeguard: 'local_partner_escrow',
        ),
        build(
          RouteType.bank,
          platformBps: 200,
          networkBps: 80,
          minSeconds: 5,
          maxSeconds: 60,
          recommended: false,
          available: bankAvailable,
          statusCode: 'instant_settlement_available',
          safeguard: 'direct_bank_treasury',
        ),
      ],
    );
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
  final session = _PreviewSession();
  return [
    configRepositoryProvider.overrideWithValue(_PreviewConfigRepository(latency)),
    ratesRepositoryProvider.overrideWithValue(_PreviewRatesRepository(latency)),
    authRepositoryProvider
        .overrideWithValue(_PreviewAuthRepository(latency, session)),
    profileRepositoryProvider
        .overrideWithValue(_PreviewProfileRepository(latency, session)),
    beneficiaryRepositoryProvider
        .overrideWithValue(_PreviewBeneficiaryRepository(latency)),
    tradeRepositoryProvider.overrideWithValue(_PreviewTradeRepository(latency)),
    tokenStorageProvider.overrideWithValue(_PreviewTokenStorage()),
  ];
}
