import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

// Test inputs only. Not app data.
class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;
  Object? lastData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

AuthRepository _repoFor(_BodyAdapter adapter) => AuthRepository(
      buildDio(
        const ApiConfig(
          baseUrl: 'http://server.invalid',
          retryBaseDelay: Duration.zero,
        ),
        adapter: adapter,
      ),
    );

void main() {
  test('verifying sends phone and code and reads the session', () async {
    final adapter = _BodyAdapter(
      '{"accessToken": "test-token", "profileComplete": false}',
    );

    final session = await _repoFor(adapter).verifyOtp(
      phone: '+999712345678',
      code: '1234',
    );

    expect(adapter.lastData, {'phone': '+999712345678', 'code': '1234'});
    expect(session.accessToken, 'test-token');
    expect(session.profileComplete, false);
  });

  test('a reply without profileComplete is rejected clearly', () async {
    final adapter = _BodyAdapter('{"accessToken": "test-token"}');

    await expectLater(
      _repoFor(adapter).verifyOtp(phone: '+999712345678', code: '1234'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
