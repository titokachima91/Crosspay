import 'package:crosspay_app/models/quote_model.dart';

/// F4.1 — what was sent on one corridor, aggregated by the server.
class CorridorSpend {
  const CorridorSpend({
    required this.from,
    required this.to,
    required this.trades,
    required this.sentMinor,
  });

  final Currency from;
  final Currency to;

  /// How many trades went over this corridor.
  final int trades;

  /// Total sent, in minor units of [from].
  final int sentMinor;
}

/// F4.1 — spending analytics. Every number here is calculated by the
/// server; the app only displays it (product rule 5).
class TradeAnalytics {
  const TradeAnalytics({
    required this.trades,
    required this.sentMinor,
    required this.sentCurrency,
    required this.receivedMinor,
    required this.receivedCurrency,
    required this.corridors,
  });

  /// Total trades counted in this window.
  final int trades;
  final int sentMinor;
  final Currency sentCurrency;
  final int receivedMinor;
  final Currency receivedCurrency;

  /// Per-corridor split, in the server's order.
  final List<CorridorSpend> corridors;
}
