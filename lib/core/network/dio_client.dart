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

/// Attaches the JWT and reports an expired session.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.tokenReader, this.onUnauthorized});

  final String? Function() tokenReader;
  final void Function()? onUnauthorized;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = tokenReader();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final sentToken = err.requestOptions.headers.containsKey('Authorization');
    if (err.response?.statusCode == 401 && sentToken) {
      onUnauthorized?.call();
    }
    handler.next(err);
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

  static const String _attemptKey = 'retryAttempt';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final attempt = (options.extra[_attemptKey] as int?) ?? 0;

    if (attempt >= maxRetries || !_isRetryable(err)) {
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
      tokenReader: tokenReader ?? () => null,
      onUnauthorized: onUnauthorized,
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
    onUnauthorized: () => ref.read(authProvider.notifier).signOut(),
  );
});
