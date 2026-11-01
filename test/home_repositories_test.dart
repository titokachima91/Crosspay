import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs only. Not app data.
class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;
  String? lastMethod;
  String? lastPath;
  Map<String, dynamic>? lastQuery;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastMethod = options.method;
    lastPath = options.path;
    lastQuery = options.queryParameters;
    return ResponseBody.fromString(
      _body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioFor(_BodyAdapter adapter) => buildDio(
      const ApiConfig(
        baseUrl: 'http://server.invalid',
        retryBaseDelay: Duration.zero,
      ),
      adapter: adapter,
    );

const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

const _config = AppConfig(
  currencies: [_a, _b],
  hubs: [TradingHub(id: 'h1', name: 'Hub One', countryCode: 'ZZ')],
  payoutRails: [PayoutRail(id: 'r1', name: 'Rail One', countryCode: 'ZZ')],
);

void main() {
  test('the profile is read, with its market and daily limit', () async {
    final repo = ProfileRepository(_dioFor(_BodyAdapter('''
      {
        "id": "u1", "phone": "+999712345678",
        "accountType": "business", "displayName": "Test Trading",
        "hubId": "h1", "kycStatus": "pending", "tier": "t1",
        "limit": {"currency": "AAA", "dailyLimitMinor": 10000, "dailyUsedMinor": 2500}
      }
    ''')));

    final profile = await repo.fetch(_config);

    expect(profile.displayName, 'Test Trading');
    expect(profile.accountType, AccountType.business);
    expect(profile.hub?.id, 'h1');
    expect(profile.kycStatus, KycStatus.pending);
    expect(profile.limitCurrency, _a);
    expect(profile.dailyRemainingMinor, 7500);
  });

  test('a profile with a currency the config does not know is rejected', () async {
    final repo = ProfileRepository(_dioFor(_BodyAdapter('''
      {
        "id": "u1", "phone": "+999712345678",
        "accountType": "personal", "displayName": "Test Person",
        "kycStatus": "verified",
        "limit": {"currency": "ZZZ", "dailyLimitMinor": 1, "dailyUsedMinor": 0}
      }
    ''')));

    await expectLater(
      repo.fetch(_config),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });

  test('saved recipients are read and unknown rails are skipped', () async {
    final repo = BeneficiaryRepository(_dioFor(_BodyAdapter('''
      {
        "beneficiaries": [
          {"id": "b1", "name": "Test Recipient", "railId": "r1",
           "accountOrPhone": "+999700000001", "kycVerified": true},
          {"id": "b2", "name": "Skipped", "railId": "nope",
           "accountOrPhone": "+999700000002", "kycVerified": false}
        ]
      }
    ''')));

    final items = await repo.list(_config);

    expect(items.length, 1);
    expect(items.single.name, 'Test Recipient');
    expect(items.single.rail.id, 'r1');
    expect(items.single.kycVerified, true);
  });

  test('an estimate is a GET with the amounts in the query', () async {
    final adapter = _BodyAdapter('''
      {"rate": 2.5, "receiveAmountMinor": 4000, "estimatedMinSeconds": 1800,
       "estimatedMaxSeconds": 7200, "route": "p2p"}
    ''');

    final estimate = await TradeRepository(_dioFor(adapter)).estimate(
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
    );

    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/api/v1/trade/estimate');
    expect(adapter.lastQuery, {
      'sendCurrency': 'AAA',
      'receiveCurrency': 'BBB',
      'sendAmountMinor': 1000,
    });
    expect(estimate.rate, 2.5);
    expect(estimate.receiveAmountMinor, 4000);
    expect(estimate.route, RouteType.p2p);
  });

  test('an estimate with an unknown route is rejected clearly', () async {
    final adapter = _BodyAdapter('''
      {"rate": 2.5, "receiveAmountMinor": 4000, "estimatedMinSeconds": 1,
       "estimatedMaxSeconds": 2, "route": "teleport"}
    ''');

    await expectLater(
      TradeRepository(_dioFor(adapter)).estimate(
        sendCurrency: _a,
        receiveCurrency: _b,
        sendAmountMinor: 1,
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
