import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

import 'support/payment_fakes.dart';

class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;
  String? lastMethod;
  String? lastPath;
  Object? lastData;
  Object? lastKey;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastMethod = options.method;
    lastPath = options.path;
    lastData = options.data;
    lastKey = options.headers['X-Idempotency-Key'];
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

const _config = AppConfig(currencies: [fakeSend, fakeReceive]);

String _trade(String status) => '''
{
  "id": "t1", "reference": "REF-1", "route": "p2p", "status": "$status",
  "sendCurrency": "AAA", "receiveCurrency": "BBB",
  "sendAmountMinor": 1000, "feeMinor": 15, "feeBps": 150,
  "receiveAmountMinor": 50000, "rate": 2.0,
  "beneficiaryName": "Test Person", "createdAt": "2026-01-01T10:00:00Z"
}
''';

void main() {
  test('initiating posts the details with the attempt key and reads both parts', () async {
    final adapter = _BodyAdapter('''
      {
        "trade": ${_trade('pending_deposit')},
        "collection": {
          "pushSent": true, "networkName": "Test Network", "amountMinor": 1015,
          "pushTimeoutSeconds": 30, "pollIntervalSeconds": 2,
          "manual": {"methodCode": "paybill", "number": "123456", "reference": "REF-1"}
        }
      }
    ''');

    final result = await _repoFor(adapter).initiate(
      quote: fakeQuote(),
      route: RouteType.p2p,
      recipient: fakeRecipient(reference: 'invoice 7'),
      idempotencyKey: 'attempt-key-1',
      config: _config,
    );

    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/api/v1/trade/initiate');
    expect(adapter.lastKey, 'attempt-key-1');
    expect(adapter.lastData, {
      'quoteId': 'q1',
      'route': 'p2p',
      'recipient': {
        'railId': 'r1',
        'account': '+888712345678',
        'name': 'Test Person',
        'reference': 'invoice 7',
      },
    });

    expect(result.trade.status, TradeStatus.pendingDeposit);
    expect(result.trade.sendCurrency, fakeSend);
    expect(result.collection.pushSent, true);
    expect(result.collection.networkName, 'Test Network');
    expect(result.collection.amountMinor, 1015);
    expect(result.collection.currency, fakeSend);
    expect(result.collection.manual?.number, '123456');
  });

  test('an empty payment reference is not sent', () async {
    final adapter = _BodyAdapter('''
      {
        "trade": ${_trade('pending_deposit')},
        "collection": {"pushSent": false, "amountMinor": 1015,
                       "pushTimeoutSeconds": 30, "pollIntervalSeconds": 2}
      }
    ''');

    final result = await _repoFor(adapter).initiate(
      quote: fakeQuote(),
      route: RouteType.p2p,
      recipient: fakeRecipient(),
      idempotencyKey: 'k',
      config: _config,
    );

    expect((adapter.lastData as Map)['recipient'], isNot(contains('reference')));
    expect(result.collection.manual, isNull);
    expect(result.collection.networkName, isNull);
  });

  test('a trade is read with a GET and its status understood', () async {
    final adapter = _BodyAdapter(_trade('escrowed'));

    final trade = await _repoFor(adapter).fetchTrade('t1', _config);

    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/api/v1/trades/t1');
    expect(trade.status, TradeStatus.escrowed);
    expect(trade.createdAt.toUtc().year, 2026);
  });

  test('cancelling and claiming use their own paths', () async {
    final cancelAdapter = _BodyAdapter(_trade('cancelled'));
    final cancelled = await _repoFor(cancelAdapter).cancelTrade('t1', idempotencyKey: 'key-1', config: _config);
    expect(cancelAdapter.lastMethod, 'POST');
    expect(cancelAdapter.lastPath, '/api/v1/trades/t1/cancel');
    expect(cancelled.status, TradeStatus.cancelled);
    expect(cancelled.isTerminal, true);

    final claimAdapter = _BodyAdapter('{}');
    await _repoFor(claimAdapter).claimManualPayment('t1');
    expect(claimAdapter.lastMethod, 'POST');
    expect(claimAdapter.lastPath, '/api/v1/trades/t1/payment-claim');
  });

  test('an unknown status or currency is rejected clearly', () async {
    await expectLater(
      _repoFor(_BodyAdapter(_trade('teleported'))).fetchTrade('t1', _config),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
    await expectLater(
      _repoFor(_BodyAdapter(_trade('escrowed')))
          .fetchTrade('t1', const AppConfig(currencies: [fakeSend])),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
