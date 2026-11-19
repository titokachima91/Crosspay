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
    final reply =
        _replies[calls < _replies.length ? calls : _replies.length - 1];
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

  test('a request marked no-retry is sent once even with an idempotency key',
      () async {
    final adapter = _ScriptedAdapter([const _Reply(503)]);
    final dio = buildDio(_config, adapter: adapter);

    await expectLater(
      dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': 'single-use'},
        options: Options(extra: {RetryInterceptor.skipRetryKey: true}),
      ),
      throwsA(isA<DioException>()),
    );

    expect(adapter.calls, 1);
  });

  test('without a server address, requests fail clearly and send nothing',
      () async {
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

  test('the token is attached when present and a 401 reports sign-out',
      () async {
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

  test('concurrent 401s replay with the refreshed token', () async {
    final adapter = _RefreshAdapter();
    var token = 'old-token';
    Future<String?>? inFlight;
    var refreshCalls = 0;
    var signedOut = false;
    final dio = buildDio(
      _config,
      adapter: adapter,
      tokenReader: () => token,
      refreshAccessToken: () {
        // Mirrors AuthNotifier.refreshAccessToken: one shared rotation.
        final existing = inFlight;
        if (existing != null) return existing;
        final future = () async {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          token = 'new-token';
          return token;
        }();
        inFlight = future;
        return future;
      },
      onUnauthorized: () => signedOut = true,
    );

    final replies = await Future.wait([
      dio.get<dynamic>('/one'),
      dio.get<dynamic>('/two'),
    ]);

    expect(replies.every((reply) => reply.statusCode == 200), true);
    expect(refreshCalls, 1);
    expect(signedOut, false);
    expect(adapter.authFor('/one'), ['Bearer old-token', 'Bearer new-token']);
    expect(adapter.authFor('/two'), ['Bearer old-token', 'Bearer new-token']);
  });

  test('a refresh that yields no token leaves the original 401 intact',
      () async {
    final adapter = _RefreshAdapter();
    var signedOut = false;
    final dio = buildDio(
      _config,
      adapter: adapter,
      tokenReader: () => 'old-token',
      refreshAccessToken: () async => null,
      onUnauthorized: () => signedOut = true,
    );

    await expectLater(
      dio.get<dynamic>('/one'),
      throwsA(
        isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401),
      ),
    );

    // The refresh callback owns sign-out on terminal refresh failures.
    expect(signedOut, false);
    expect(adapter.refreshCalls, 0);
    expect(adapter.authFor('/one'), ['Bearer old-token']);
  });
}

/// Answers protected paths with 401 until the bearer token is `new-token`,
/// and always accepts the refresh path.
class _RefreshAdapter implements HttpClientAdapter {
  int refreshCalls = 0;
  final Map<String, List<String?>> authByPath = {};

  List<String?> authFor(String path) => authByPath[path] ?? const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    final auth = options.headers['Authorization'] as String?;
    if (path.endsWith('/auth/refresh')) {
      refreshCalls++;
      return ResponseBody.fromString(
        '{"accessToken":"new-token","refreshToken":"new-refresh",'
        '"expiresInSeconds":900}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    authByPath.putIfAbsent(path, () => []).add(auth);
    final refreshed = auth == 'Bearer new-token';
    return ResponseBody.fromString(
      refreshed
          ? '{"ok":true}'
          : '{"error":{"code":"UNAUTHORIZED","message":"expired"}}',
      refreshed ? 200 : 401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
