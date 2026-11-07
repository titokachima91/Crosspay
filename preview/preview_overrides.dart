// SIMULATED DATA LIVES HERE AND ONLY HERE.
// The real app (lib/) never imports this folder; a test enforces that.
// Deleting the preview/ folder removes every simulated value.

import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/analytics_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/market_depth_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_event_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
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
    PayoutRail(
      id: 'rail-1',
      name: 'Preview mobile money (Kenya)',
      countryCode: 'KE',
      kind: PayoutKind.mobileMoney,
    ),
    PayoutRail(
      id: 'rail-2',
      name: 'Preview bank transfer (Kenya)',
      countryCode: 'KE',
      kind: PayoutKind.bank,
    ),
    PayoutRail(
      id: 'rail-3',
      name: 'Preview mobile money (Tanzania)',
      countryCode: 'TZ',
      kind: PayoutKind.mobileMoney,
    ),
    PayoutRail(
      id: 'rail-4',
      name: 'Preview bank transfer (Tanzania)',
      countryCode: 'TZ',
      kind: PayoutKind.bank,
    ),
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

  /// F4.2 — simulated corridor depth for the Rates tab.
  @override
  Future<List<CorridorDepth>> fetchDepth(AppConfig config) async {
    await _wait(_latency);
    final tzs = config.currencyByCode('TZS');
    final kes = config.currencyByCode('KES');
    if (tzs == null || kes == null) return const [];
    return [
      CorridorDepth(
        from: tzs,
        to: kes,
        queueDepth: 12,
        estimatedSettleSeconds: 900,
        status: const CorridorStatus(
          code: 'balanced_p2p',
          level: CorridorLevel.healthy,
        ),
      ),
      CorridorDepth(
        from: kes,
        to: tzs,
        queueDepth: 4,
        estimatedSettleSeconds: 420,
        status: const CorridorStatus(
          code: 'active_clearing',
          level: CorridorLevel.limited,
        ),
      ),
    ];
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

  /// Simulated recipients, seeded once so add / edit / delete stick in the demo.
  List<Beneficiary>? _items;
  int _nextId = 5;

  @override
  Future<List<Beneficiary>> list(AppConfig config) async {
    await _wait(_latency);
    if (config.payoutRails.isEmpty) return const [];
    final rail = config.payoutRails.first;
    _items ??= [
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
    return List<Beneficiary>.unmodifiable(_items!);
  }

  /// F5.2 — the demo accepts a new recipient and keeps it for the session.
  @override
  Future<Beneficiary> add({
    required AppConfig config,
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) async {
    await _wait(_latency);
    final item = Beneficiary(
      id: 'p${_nextId++}',
      name: name,
      rail: rail,
      accountOrPhone: accountOrPhone,
    );
    _items?.add(item);
    return item;
  }

  /// F5.2 — edits a recipient already in the demo list.
  @override
  Future<Beneficiary> update({
    required AppConfig config,
    required String id,
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) async {
    await _wait(_latency);
    final item = Beneficiary(
      id: id,
      name: name,
      rail: rail,
      accountOrPhone: accountOrPhone,
    );
    final index = _items?.indexWhere((b) => b.id == id) ?? -1;
    if (index >= 0) _items![index] = item;
    return item;
  }

  /// F5.2 — removes a recipient from the demo list.
  @override
  Future<void> remove(String id) async {
    await _wait(_latency);
    _items?.removeWhere((b) => b.id == id);
  }

  /// An account ending in 0 is "not found". A name containing "mismatch" does
  /// not match; "unverifiable" cannot be checked; bank accounts cannot have
  /// their name checked automatically; anything else matches.
  @override
  Future<RecipientCheck> check({
    required PayoutRail rail,
    required String account,
    String? name,
  }) async {
    await _wait(_latency);
    if (account.endsWith('0')) {
      return const RecipientCheck(accountStatus: AccountStatus.notFound);
    }

    NameMatch? match;
    if (name != null) {
      final lower = name.toLowerCase();
      if (lower.contains('mismatch')) {
        match = NameMatch.mismatch;
      } else if (lower.contains('unverifiable') || rail.kind == PayoutKind.bank) {
        match = NameMatch.unavailable;
      } else {
        match = NameMatch.match;
      }
    }
    return RecipientCheck(
      accountStatus: AccountStatus.found,
      networkName: rail.name,
      nameMatch: match,
    );
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

  // --- Payment simulation (F3.4) ---
  Trade? _trade;
  int _polls = 0;
  bool _claimed = false;
  bool _neverConfirms = false;

  /// A payment reference containing "nopush" means no prompt is sent; one
  /// containing "timeout" never confirms by itself. Otherwise the deposit is
  /// "received" after about three checks. Tapping "I have completed manual
  /// payment" confirms it at the next check.
  @override
  Future<InitiatedTrade> initiate({
    required Quote quote,
    required RouteType route,
    required RecipientDetails recipient,
    required String idempotencyKey,
    required AppConfig config,
  }) async {
    await _wait(_latency);
    final option = quote.forRoute(route);
    if (option == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 400,
        code: 'CORRIDOR_UNAVAILABLE',
      );
    }

    final reference = recipient.reference.toLowerCase();
    final pushSent = !reference.contains('nopush');
    _neverConfirms = !pushSent || reference.contains('timeout');
    _polls = 0;
    _claimed = false;

    final trade = Trade(
      id: 'preview-trade-1',
      reference: 'PV-0001',
      route: route,
      status: TradeStatus.pendingDeposit,
      sendCurrency: quote.sendCurrency,
      receiveCurrency: quote.receiveCurrency,
      sendAmountMinor: quote.sendAmountMinor,
      feeMinor: option.feeMinor,
      feeBps: option.feeBps,
      receiveAmountMinor: option.payoutMinor,
      rate: quote.rate,
      beneficiaryName: recipient.name,
      createdAt: DateTime.now(),
    );
    _trade = trade;

    return InitiatedTrade(
      trade: trade,
      collection: CollectionInstructions(
        pushSent: pushSent,
        networkName: 'Preview mobile money',
        amountMinor: option.totalDebitMinor,
        currency: quote.sendCurrency,
        pushTimeoutSeconds: 12,
        pollIntervalSeconds: 2,
        manual: const ManualPayment(
          methodCode: 'paybill',
          number: '000000',
          reference: 'PV-0001',
        ),
      ),
    );
  }

  @override
  Future<Trade> fetchTrade(String id, AppConfig config) async {
    await _wait(_latency);
    final trade = _trade;
    if (trade == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 404,
        code: 'TRADE_NOT_FOUND',
      );
    }
    _polls++;
    if (trade.status == TradeStatus.pendingDeposit &&
        (_claimed || (!_neverConfirms && _polls >= 3))) {
      _trade = trade.copyWith(status: TradeStatus.escrowed);
    }
    return _trade!;
  }

  @override
  Future<void> claimManualPayment(String tradeId) async {
    await _wait(_latency);
    _claimed = true;
  }

  @override
  Future<Trade> cancelTrade(String tradeId, {required String idempotencyKey, required AppConfig config}) async {
    await _wait(_latency);
    final trade = _trade;
    if (trade == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 404,
        code: 'TRADE_NOT_FOUND',
      );
    }
    _trade = trade.copyWith(status: TradeStatus.cancelled);
    return _trade!;
  }

  @override
  Future<Invoice> getInvoice(String tradeId, {required AppConfig config}) async {
    await _wait(_latency);
    final trade = _trade;
    if (trade == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 404,
        code: 'TRADE_NOT_FOUND',
      );
    }
    return Invoice(
      tradeId: trade.id,
      qrCodeUrl: 'preview://qr/${trade.id}',
      shareUrl: 'preview://trade/${trade.id}',
      validUntil: DateTime.now().add(const Duration(hours: 24)),
      amount: trade.sendAmountMinor,
      currency: trade.sendCurrency.code,
    );
  }

  @override
  Future<void> shareTrade(String tradeId, {required String idempotencyKey, required AppConfig config}) async {
    await _wait(_latency);
    final trade = _trade;
    if (trade == null) {
      throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 404,
        code: 'TRADE_NOT_FOUND',
      );
    }
    _shared = true;
  }

  /// F4.1 — simulated trade history, newest first.
  @override
  Future<List<Trade>> getTrades(AppConfig config) async {
    await _wait(_latency);
    final tzs = config.currencyByCode('TZS') ?? _tzs;
    final kes = config.currencyByCode('KES') ?? _kes;
    final now = DateTime.now();
    return [
      Trade(
        id: 'pv-1041',
        reference: 'PV-1041',
        route: RouteType.p2p,
        status: TradeStatus.pendingDeposit,
        sendCurrency: tzs,
        receiveCurrency: kes,
        sendAmountMinor: 1200000,
        feeMinor: 12000,
        feeBps: 100,
        receiveAmountMinor: 24300,
        rate: 0.0504,
        beneficiaryName: 'Eastleigh Textiles',
        createdAt: now.subtract(const Duration(hours: 3)),
      ),
      Trade(
        id: 'pv-1040',
        reference: 'PV-1040',
        route: RouteType.p2p,
        status: TradeStatus.completed,
        sendCurrency: tzs,
        receiveCurrency: kes,
        sendAmountMinor: 2400000,
        feeMinor: 24000,
        feeBps: 100,
        receiveAmountMinor: 48600,
        rate: 0.0504,
        beneficiaryName: 'Lusaka Import Export',
        createdAt: now.subtract(const Duration(days: 12)),
      ),
      Trade(
        id: 'pv-1039',
        reference: 'PV-1039',
        route: RouteType.bank,
        status: TradeStatus.failed,
        sendCurrency: kes,
        receiveCurrency: tzs,
        sendAmountMinor: 80000,
        feeMinor: 800,
        feeBps: 100,
        receiveAmountMinor: 1588000,
        rate: 19.85,
        beneficiaryName: 'Nairobi Motors',
        createdAt: now.subtract(const Duration(days: 45)),
      ),
    ];
  }

  /// F4.1 — a status timeline for the trade on screen.
  @override
  Future<List<TradeEvent>> fetchTimeline(String tradeId) async {
    await _wait(_latency);
    final now = DateTime.now();
    return [
      TradeEvent(
        status: TradeStatus.pendingDeposit,
        at: now.subtract(const Duration(minutes: 42)),
      ),
      TradeEvent(
        status: TradeStatus.escrowed,
        at: now.subtract(const Duration(minutes: 38)),
        noteCode: 'payment_seen',
      ),
      TradeEvent(
        status: TradeStatus.matching,
        at: now.subtract(const Duration(minutes: 31)),
      ),
    ];
  }

  /// F4.1 — an export link to copy (nothing is actually served).
  @override
  Future<ExportTicket> requestExport() async {
    await _wait(_latency);
    return ExportTicket(
      downloadUrl: 'preview://trades/export.csv',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );
  }

  /// F4.1 — simulated analytics for the spending screen.
  @override
  Future<TradeAnalytics> fetchAnalytics(AppConfig config) async {
    await _wait(_latency);
    final tzs = config.currencyByCode('TZS') ?? _tzs;
    final kes = config.currencyByCode('KES') ?? _kes;
    return TradeAnalytics(
      trades: 3,
      sentMinor: 2480000,
      sentCurrency: tzs,
      receivedMinor: 72900,
      receivedCurrency: kes,
      corridors: const [
        CorridorSpend(
          from: _tzs,
          to: _kes,
          trades: 2,
          sentMinor: 3600000,
        ),
        CorridorSpend(
          from: _kes,
          to: _tzs,
          trades: 1,
          sentMinor: 80000,
        ),
      ],
    );
  }

  bool get shared => _shared;
  bool _shared = false;
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
