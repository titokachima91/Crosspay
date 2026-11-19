import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_constants.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/idempotency_interceptor.dart';
import 'package:crosspay_app/providers/auth_provider.dart';

/// Networking settings. The server address comes from the build, never the code.
class ApiConfig {
  const ApiConfig({
    required this.baseUrl,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 500),
  });

  final String baseUrl;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final int maxRetries;
  final Duration retryBaseDelay;

  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// Fails fast, with a clear error, when no server address was provided.
class _ConfigGuardInterceptor extends Interceptor {
  _ConfigGuardInterceptor(this._config);

  final ApiConfig _config;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_config.isConfigured) {
      handler.next(options);
      return;
    }
    handler.reject(
      DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: const ApiException(kind: ApiErrorKind.notConfigured),
      ),
    );
  }
}

/// Attaches the JWT and transparently renews it.
///
/// A 401 on a request that carried an access token asks the refresh callback
/// for a new token and replays the request once. The callback is single-flight
/// (see AuthNotifier), so a burst of expired requests triggers exactly one
/// refresh call and all of them replay with the new token. Rejected or missing
/// refresh tokens sign the session out; a network failure keeps it for retry.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.dio,
    required this.tokenReader,
    this.onUnauthorized,
    this.refreshAccessToken,
  });

  /// Set on the refresh request itself so a rejected refresh is never retried
  /// through the refresh path (which would recurse).
  static const String skipRefreshKey = 'skipAuthRefresh';
  static const String _replayedKey = 'authReplayed';

  final Dio dio;
  final String? Function() tokenReader;
  final void Function()? onUnauthorized;
  final Future<String?> Function()? refreshAccessToken;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.extra[skipRefreshKey] == true) {
      options.headers.remove('Authorization');
      handler.next(options);
      return;
    }
    final token = tokenReader();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final isUnauthorized = err.response?.statusCode == 401;
    final sentToken = options.headers.containsKey('Authorization');
    final skipped = options.extra[skipRefreshKey] == true;
    final refresh = refreshAccessToken;

    if (!isUnauthorized || !sentToken || skipped || refresh == null) {
      if (isUnauthorized && sentToken && !skipped) onUnauthorized?.call();
      handler.next(err);
      return;
    }

    if (options.extra[_replayedKey] == true) {
      // The fresh token was also rejected: the session is over.
      onUnauthorized?.call();
      handler.next(err);
      return;
    }

    final token = await refresh();
    if (token == null || token.isEmpty) {
      // The refresh callback already signed out if the failure was terminal.
      handler.next(err);
      return;
    }

    options.extra[_replayedKey] = true;
    options.headers['Authorization'] = 'Bearer $token';
    try {
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}

/// Retries network drops, timeouts and 502/503/504 with growing delays.
/// Changing requests are only retried because they carry an idempotency key.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    required this.maxRetries,
    required this.baseDelay,
  });

  final Dio dio;
  final int maxRetries;
  final Duration baseDelay;

  /// A server action that must not be replayed even when the request carries
  /// an idempotency key (for example a refresh-token rotation).
  static const String skipRetryKey = 'skipRetry';

  static const String _attemptKey = 'retryAttempt';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final attempt = (options.extra[_attemptKey] as int?) ?? 0;

    if (attempt >= maxRetries ||
        options.extra[skipRetryKey] == true ||
        !_isRetryable(err)) {
      handler.next(err);
      return;
    }

    options.extra[_attemptKey] = attempt + 1;
    final delay = baseDelay * (1 << attempt);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    try {
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  bool _isRetryable(DioException err) {
    if (!_isSafeToRepeat(err.requestOptions)) return false;
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode;
        return status == 502 || status == 503 || status == 504;
      case DioExceptionType.transformTimeout:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        return false;
    }
  }

  bool _isSafeToRepeat(RequestOptions options) {
    final method = options.method.toUpperCase();
    return method == 'GET' ||
        method == 'HEAD' ||
        options.headers.containsKey(IdempotencyInterceptor.headerName);
  }
}

/// Builds the configured Dio instance. Kept separate from Riverpod so it can
/// be tested directly.
Dio buildDio(
  ApiConfig config, {
  String? Function()? tokenReader,
  void Function()? onUnauthorized,
  Future<String?> Function()? refreshAccessToken,
  HttpClientAdapter? adapter,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: config.baseUrl,
      connectTimeout: config.connectTimeout,
      receiveTimeout: config.receiveTimeout,
      contentType: Headers.jsonContentType,
      headers: {'Accept': Headers.jsonContentType},
    ),
  );

  if (adapter != null) {
    dio.httpClientAdapter = adapter;
  }

  dio.interceptors.addAll([
    _ConfigGuardInterceptor(config),
    IdempotencyInterceptor(),
    AuthInterceptor(
      dio: dio,
      tokenReader: tokenReader ?? () => null,
      onUnauthorized: onUnauthorized,
      refreshAccessToken: refreshAccessToken,
    ),
    RetryInterceptor(
      dio: dio,
      maxRetries: config.maxRetries,
      baseDelay: config.retryBaseDelay,
    ),
  ]);

  return dio;
}

final apiConfigProvider = Provider<ApiConfig>(
  (ref) => const ApiConfig(baseUrl: AppConstants.apiBaseUrl),
);

final dioProvider = Provider<Dio>((ref) {
  return buildDio(
    ref.watch(apiConfigProvider),
    tokenReader: () => ref.read(authProvider).accessToken,
    refreshAccessToken: () =>
        ref.read(authProvider.notifier).refreshAccessToken(),
    onUnauthorized: () => ref.read(authProvider.notifier).signOut(),
  );
});
