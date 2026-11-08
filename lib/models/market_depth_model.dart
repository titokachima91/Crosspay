import 'package:crosspay_app/models/quote_model.dart';

/// F4.2 — queue depth and health for one corridor, as reported by the
/// server. The app displays these numbers; it never estimates them.
class CorridorDepth {
  const CorridorDepth({
    required this.from,
    required this.to,
    required this.queueDepth,
    required this.estimatedSettleSeconds,
    this.status,
  });

  final Currency from;
  final Currency to;

  /// How many trades are waiting on this corridor right now.
  final int queueDepth;

  /// The server's estimate of how long a payout takes on this corridor.
  final int estimatedSettleSeconds;

  /// Present only when the server sent a health status for the corridor.
  final CorridorStatus? status;
}
