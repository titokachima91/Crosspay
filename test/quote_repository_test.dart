import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs only. Not app data.
class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;
  String? lastMethod;
  String? lastPath;
  Object? lastData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastMethod = options.method;
    lastPath = options.path;
    lastData = options.data;
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

TradeRepository _repoFor(_BodyAdapter adapter) => TradeRepository(
      buildDio(
        const ApiConfig(
          baseUrl: 'http://server.invalid',
          retryBaseDelay: Duration.zero,
        ),
        adapter: adapter,
      ),
    );

const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

String _body({required DateTime serverTime, required DateTime expiresAt}) => '''
{
  "id": "q1", "rate": 2.5,
  "serverTime": "${serverTime.toUtc().toIso8601String()}",
  "expiresAt": "${expiresAt.toUtc().toIso8601String()}",
  "routes": [
    {"route": "p2p", "feeBps": 150, "feeMinor": 15, "payoutMinor": 40000,
     "totalDebitMinor": 1015, "estimatedMinSeconds": 1800,
     "estimatedMaxSeconds": 7200, "isRecommended": true, "isAvailable": true,
     "matchingDensityPercent": 72,
     "status": {"code": "high_matching_density", "level": "healthy"},
     "safeguardCode": "local_partner_escrow",
     "breakdown": [{"code": "platform_fee", "amountMinor": 10},
                   {"code": "network_fee", "amountMinor": 5}]},
    {"route": "bank", "feeBps": 280, "feeMinor": 28, "payoutMinor": 40000,
     "totalDebitMinor": 1028, "estimatedMinSeconds": 5,
     "estimatedMaxSeconds": 60, "isRecommended": false, "isAvailable": false,
     "breakdown": []}
  ]
}
''';

void main() {
  test('a quote is a POST and its routes are read in full', () async {
    final now = DateTime.now();
    final adapter = _BodyAdapter(_body(
      serverTime: now,
      expiresAt: now.add(const Duration(seconds: 300)),
    ));

    final quote = await _repoFor(adapter).quote(
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
    );

    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/api/v1/trade/quote');
    expect(adapter.lastData, {
      'sendCurrency': 'AAA',
      'receiveCurrency': 'BBB',
      'sendAmountMinor': 1000,
    });

    expect(quote.id, 'q1');
    expect(quote.routes.length, 2);

    final p2p = quote.forRoute(RouteType.p2p)!;
    expect(p2p.totalDebitMinor, 1015);
    expect(p2p.payoutMinor, 40000);
    expect(p2p.status?.level, CorridorLevel.healthy);
    expect(p2p.safeguardCode, 'local_partner_escrow');
    expect(p2p.breakdown.map((l) => l.code), ['platform_fee', 'network_fee']);

    final bank = quote.forRoute(RouteType.bank)!;
    expect(bank.isAvailable, false);
    expect(bank.safeguardCode, isNull);
    expect(bank.breakdown, isEmpty);
  });

  test('the countdown follows the server clock, not the phone clock', () async {
    // The server's clock is one hour ahead of this phone.
    final serverTime = DateTime.now().toUtc().add(const Duration(hours: 1));
    final adapter = _BodyAdapter(_body(
      serverTime: serverTime,
      expiresAt: serverTime.add(const Duration(seconds: 300)),
    ));

    final quote = await _repoFor(adapter).quote(
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
    );

    expect(quote.clockOffset.inSeconds, inInclusiveRange(3590, 3600));
    expect(
      quote.remainingAt(DateTime.now()).inSeconds,
      inInclusiveRange(295, 300),
    );
  });

  test('a reply with a bad time is rejected clearly', () async {
    final adapter = _BodyAdapter(
      _body(serverTime: DateTime.now(), expiresAt: DateTime.now())
          .replaceFirst(RegExp(r'"expiresAt": "[^"]*"'), '"expiresAt": "soon"'),
    );

    await expectLater(
      _repoFor(adapter).quote(
        sendCurrency: _a,
        receiveCurrency: _b,
        sendAmountMinor: 1000,
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
