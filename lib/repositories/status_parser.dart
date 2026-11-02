import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/quote_model.dart';

/// Reads { "code": "...", "level": "healthy | limited | down" }.
/// An unknown level is treated as "no status" instead of an error.
CorridorStatus? parseCorridorStatus(JsonReader? json) {
  if (json == null) return null;

  final level = switch (json.string('level')) {
    'healthy' => CorridorLevel.healthy,
    'limited' => CorridorLevel.limited,
    'down' => CorridorLevel.down,
    _ => null,
  };
  if (level == null) return null;

  return CorridorStatus(code: json.string('code'), level: level);
}
