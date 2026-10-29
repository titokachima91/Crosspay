import 'package:dio/dio.dart';

enum ApiErrorKind {
  notConfigured,
  network,
  timeout,
  unauthorized,
  client,
  server,
  cancelled,
  unknown,
}

/// The single error type the rest of the app deals with.
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    this.statusCode,
    this.code,
    this.serverMessage,
  });

  final ApiErrorKind kind;
  final int? statusCode;

  /// Machine-readable code from the server, e.g. QUOTE_EXPIRED.
  final String? code;

  /// For logs only. Never shown to users; the UI uses [messageKey].
  final String? serverMessage;

  /// Localization key for a general, user-facing message.
  String get messageKey => 'error.${kind.name}';

  factory ApiException.fromDio(DioException e) {
    final inner = e.error;
    if (inner is ApiException) return inner;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ApiException(kind: ApiErrorKind.timeout);
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return const ApiException(kind: ApiErrorKind.network);
      case DioExceptionType.cancel:
        return const ApiException(kind: ApiErrorKind.cancelled);
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode;
        final parsed = _parseEnvelope(e.response?.data);
        final ApiErrorKind kind;
        if (status == 401) {
          kind = ApiErrorKind.unauthorized;
        } else if (status != null && status >= 500) {
          kind = ApiErrorKind.server;
        } else {
          kind = ApiErrorKind.client;
        }
        return ApiException(
          kind: kind,
          statusCode: status,
          code: parsed.$1,
          serverMessage: parsed.$2,
        );
      case DioExceptionType.unknown:
        return const ApiException(kind: ApiErrorKind.unknown);
    }
  }

  /// Expected error body: { "error": { "code": "...", "message": "..." } }
  static (String?, String?) _parseEnvelope(Object? data) {
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        final code = error['code'];
        final message = error['message'];
        return (
          code is String ? code : null,
          message is String ? message : null,
        );
      }
    }
    return (null, null);
  }

  @override
  String toString() =>
      'ApiException(${kind.name}, status: $statusCode, code: $code)';
}
