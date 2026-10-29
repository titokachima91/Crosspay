import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/core/network/idempotency_interceptor.dart';

// Test inputs only. Not app data.
class _Reply {
  const _Reply(this.status, [this.body = '{}']);
  final int status;
  final String body;
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._replies);

  final List<_Reply> _replies;
  int calls = 0;
  final List<Object?> keys = [];
  final List<Object?> auth = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final reply = _replies[calls < _replies.length ? calls : _replies.length - 1];
    calls++;
    keys.add(options.headers[IdempotencyInterceptor.headerName]);
    auth.add(options.headers['Authorization']);
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _config = ApiConfig(
  baseUrl: 'http://server.invalid',
  maxRetries: 2,
  retryBaseDelay: Duration.zero,
);

void main() {
  test('changing requests get an idempotency key, reads do not', () async {
    final adapter = _ScriptedAdapter([const _Reply(200)]);
    final dio = buildDio(_config, adapter: adapter);

    await dio.get<dynamic>('/x');
    await dio.post<dynamic>('/x', data: {});

    expect(adapter.keys[0], isNull);
    expect(adapter.keys[1], isNotNull);
  });

  test('a caller-supplied key is used as given', () async {
    final adapter = _ScriptedAdapter([const _Reply(200)]);
    final dio = buildDio(_config, adapter: adapter);

    await dio.post<dynamic>(
      '/x',
      data: {},
      options: Options(extra: {IdempotencyInterceptor.extraKey: 'key-1'}),
    );

    expect(adapter.keys.single, 'key-1');
  });

  test('a retried request reuses the same idempotency key', () async {
    final adapter = _ScriptedAdapter([const _Reply(503), const _Reply(200)]);
    final dio = buildDio(_config, adapter: adapter);

    await dio.post<dynamic>('/x', data: {});

    expect(adapter.calls, 2);
    expect(adapter.keys[0], isNotNull);
    expect(adapter.keys[0], adapter.keys[1]);
  });

  test('gives up after the maximum number of retries', () async {
    final adapter = _ScriptedAdapter([const _Reply(503)]);
    final dio = buildDio(_config, adapter: adapter);

    await expectLater(dio.get<dynamic>('/x'), throwsA(isA<DioException>()));
    expect(adapter.calls, 3); // first try + 2 retries
  });

  test('a client error is not retried and keeps the server code', () async {
    final adapter = _ScriptedAdapter([
      const _Reply(400, '{"error":{"code":"SOME_CODE","message":"detail"}}'),
    ]);
    final dio = buildDio(_config, adapter: adapter);

    try {
      await dio.post<dynamic>('/x', data: {});
      fail('expected an error');
    } on DioException catch (e) {
      final ex = ApiException.fromDio(e);
      expect(ex.kind, ApiErrorKind.client);
      expect(ex.statusCode, 400);
      expect(ex.code, 'SOME_CODE');
      expect(ex.messageKey, 'error.client');
    }
    expect(adapter.calls, 1);
  });

  test('without a server address, requests fail clearly and send nothing', () async {
    final adapter = _ScriptedAdapter([const _Reply(200)]);
    final dio = buildDio(const ApiConfig(baseUrl: ''), adapter: adapter);

    try {
      await dio.get<dynamic>('/x');
      fail('expected an error');
    } on DioException catch (e) {
      expect(ApiException.fromDio(e).kind, ApiErrorKind.notConfigured);
    }
    expect(adapter.calls, 0);
  });

  test('the token is attached when present and a 401 reports sign-out', () async {
    final adapter = _ScriptedAdapter([const _Reply(401)]);
    var signedOut = false;
    final dio = buildDio(
      _config,
      adapter: adapter,
      tokenReader: () => 'test-token',
      onUnauthorized: () => signedOut = true,
    );

    await expectLater(dio.get<dynamic>('/x'), throwsA(isA<DioException>()));

    expect(adapter.auth.first, 'Bearer test-token');
    expect(signedOut, true);
    expect(adapter.calls, 1);
  });
}
