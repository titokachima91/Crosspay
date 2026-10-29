import 'package:crosspay_app/core/network/api_exception.dart';

/// Reads server JSON safely. Any missing or wrongly typed field becomes an
/// ApiException (INVALID_RESPONSE) instead of a crash deep in the UI.
class JsonReader {
  JsonReader._(this._map);

  final Map<String, dynamic> _map;

  factory JsonReader.of(Object? value) {
    if (value is Map<String, dynamic>) return JsonReader._(value);
    throw _invalid('response body');
  }

  static ApiException _invalid(String what) => ApiException(
        kind: ApiErrorKind.unknown,
        code: 'INVALID_RESPONSE',
        serverMessage: 'Unexpected format: $what',
      );

  String string(String key) {
    final v = _map[key];
    if (v is String) return v;
    throw _invalid(key);
  }

  String? optionalString(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is String) return v;
    throw _invalid(key);
  }

  int integer(String key) {
    final v = _map[key];
    if (v is num) return v.toInt();
    throw _invalid(key);
  }

  int? optionalInt(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is num) return v.toInt();
    throw _invalid(key);
  }

  double number(String key) {
    final v = _map[key];
    if (v is num) return v.toDouble();
    throw _invalid(key);
  }

  double? optionalNumber(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw _invalid(key);
  }

  JsonReader? optionalObject(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is Map<String, dynamic>) return JsonReader._(v);
    throw _invalid(key);
  }

  List<JsonReader> list(String key) {
    final v = _map[key];
    if (v is! List) throw _invalid(key);
    return [
      for (final item in v)
        if (item is Map<String, dynamic>) JsonReader._(item) else throw _invalid(key),
    ];
  }
}
