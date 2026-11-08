import 'package:crosspay_app/models/trade_model.dart';

/// F4.1 — one step a trade went through, exactly as the server recorded it.
/// The app never derives these itself; it only displays what the server sent.
class TradeEvent {
  const TradeEvent({required this.status, required this.at, this.noteCode});

  /// The status the trade moved into at [at].
  final TradeStatus status;

  /// When the server recorded the change.
  final DateTime at;

  /// Optional server code describing the change, e.g. 'payment_seen'.
  /// An unknown code is simply not shown; the status label always is.
  final String? noteCode;
}
