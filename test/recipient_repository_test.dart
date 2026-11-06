import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';

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

BeneficiaryRepository _repoFor(_BodyAdapter adapter) => BeneficiaryRepository(
      buildDio(
        const ApiConfig(
          baseUrl: 'http://server.invalid',
          retryBaseDelay: Duration.zero,
        ),
        adapter: adapter,
      ),
    );

const _rail = PayoutRail(
  id: 'r1',
  name: 'Test Rail',
  countryCode: 'ZZ',
  kind: PayoutKind.mobileMoney,
);

void main() {
  test('a check posts the rail, account and name, and reads the answer', () async {
    final adapter = _BodyAdapter(
      '{"accountStatus": "found", "networkName": "Test Network", "nameMatch": "match"}',
    );

    final check = await _repoFor(adapter).check(
      rail: _rail,
      account: '+999712345678',
      name: 'Test Person',
    );

    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/api/v1/beneficiaries/check');
    expect(adapter.lastData, {
      'railId': 'r1',
      'account': '+999712345678',
      'name': 'Test Person',
    });
    expect(check.accountStatus, AccountStatus.found);
    expect(check.networkName, 'Test Network');
    expect(check.nameMatch, NameMatch.match);
  });

  test('without a name none is sent and no match is reported', () async {
    final adapter = _BodyAdapter('{"accountStatus": "not_found"}');

    final check = await _repoFor(adapter).check(
      rail: _rail,
      account: '+999712345670',
    );

    expect(adapter.lastData, {'railId': 'r1', 'account': '+999712345670'});
    expect(check.accountStatus, AccountStatus.notFound);
    expect(check.nameMatch, isNull);
  });

  test('an unknown answer is rejected clearly', () async {
    await expectLater(
      _repoFor(_BodyAdapter('{"accountStatus": "maybe"}'))
          .check(rail: _rail, account: '+999712345678'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
    await expectLater(
      _repoFor(_BodyAdapter('{"accountStatus": "found", "nameMatch": "kind of"}'))
          .check(rail: _rail, account: '+999712345678', name: 'a'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });

  test('a saved international number is shown without its calling code', () {
    const country = Country(
      code: 'ZZ',
      name: 'Testland',
      dialCode: '999',
      nationalNumberLength: 9,
    );
    expect(
      PhoneUtils.nationalFromInternational('+999712345678', country),
      '712345678',
    );
    expect(
      PhoneUtils.nationalFromInternational('712345678', country),
      '712345678',
    );
  });
}
