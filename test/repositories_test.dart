import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

// Test inputs only. Not app data.
class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

Dio _dioReturning(String body) => buildDio(
      const ApiConfig(
        baseUrl: 'http://server.invalid',
        retryBaseDelay: Duration.zero,
      ),
      adapter: _BodyAdapter(body),
    );

const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ');
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ');

void main() {
  test('config is read from the server reply', () async {
    final repo = ConfigRepository(_dioReturning('''
      {
        "currencies": [{"code": "AAA", "name": "Alpha", "countryCode": "ZZ"}],
        "hubs": [{"id": "h1", "name": "Hub one", "countryCode": "ZZ"}],
        "payoutRails": [{"id": "r1", "name": "Rail one", "countryCode": "ZZ"}]
      }
    '''));

    final config = await repo.fetch();

    expect(config.currencies.single.code, 'AAA');
    expect(config.currencies.single.countryCode, 'ZZ');
    expect(config.hubs.single.id, 'h1');
    expect(config.payoutRails.single.name, 'Rail one');
  });

  test('rates are read, unknown currencies skipped, status parsed', () async {
    final repo = RatesRepository(_dioReturning('''
      {
        "rates": [
          {"from": "AAA", "to": "BBB", "rate": 2.5,
           "status": {"code": "some_code", "level": "healthy"}},
          {"from": "AAA", "to": "CCC", "rate": 9.0}
        ],
        "queueHealth": {"p2pDensityPercent": 40, "bankSweepPercent": 60}
      }
    '''));

    final snapshot = await repo.fetch(
      const AppConfig(currencies: [_a, _b]),
    );

    expect(snapshot.rates.length, 1);
    expect(snapshot.rates.single.rate, 2.5);
    expect(snapshot.rates.single.status?.level, CorridorLevel.healthy);
    expect(snapshot.rates.single.status?.code, 'some_code');
    expect(snapshot.p2pDensityPercent, 40);
    expect(snapshot.bankSweepPercent, 60);
  });

  test('a malformed reply becomes a clear INVALID_RESPONSE error', () async {
    final repo = ConfigRepository(_dioReturning('{"currencies": "oops"}'));

    await expectLater(
      repo.fetch(),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
