import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Adds an X-Idempotency-Key to every request that changes data.
///
/// A key is created once per request and kept across automatic retries, so
/// the server can recognise a repeat. For money actions, the caller should
/// create ONE key per user intent and pass it in
/// `Options(extra: {IdempotencyInterceptor.extraKey: key})`, so even a fresh
/// tap on "try again" reuses the same key.
class IdempotencyInterceptor extends Interceptor {
  IdempotencyInterceptor({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  static const String headerName = 'X-Idempotency-Key';
  static const String extraKey = 'idempotencyKey';
  static const Set<String> _changingMethods = {'POST', 'PUT', 'PATCH', 'DELETE'};

  final Uuid _uuid;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final changesData = _changingMethods.contains(options.method.toUpperCase());
    if (changesData && !options.headers.containsKey(headerName)) {
      final supplied = options.extra[extraKey];
      options.headers[headerName] =
          (supplied is String && supplied.isNotEmpty) ? supplied : _uuid.v4();
    }
    handler.next(options);
  }
}
