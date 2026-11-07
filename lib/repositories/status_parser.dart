import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/json_reader.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';

/// Reads the trade status the server sends. An unknown code is an error,
/// never a guess: only the server decides the state of a trade
/// (product rule 11).
TradeStatus parseTradeStatus(String value) => switch (value) {
      'pending_deposit' => TradeStatus.pendingDeposit,
      'escrowed' => TradeStatus.escrowed,
      'matching' => TradeStatus.matching,
      'matched' => TradeStatus.matched,
      'disbursing' => TradeStatus.disbursing,
      'completed' => TradeStatus.completed,
      'expired' => TradeStatus.expired,
      'refunded' => TradeStatus.refunded,
      'failed' => TradeStatus.failed,
      'cancelled' => TradeStatus.cancelled,
      _ => throw ApiException.invalidResponse('status'),
    };

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
