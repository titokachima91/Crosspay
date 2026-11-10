import 'package:crosspay_app/models/trade_model.dart';

/// The trade details carried into the support screen.
///
/// Reference-level data only: no beneficiary name, account number or other
/// personal data is copied into support metadata.
class SupportTradeContext {
  const SupportTradeContext({
    required this.tradeId,
    required this.reference,
    this.status,
    this.verificationHash,
  });

  final String tradeId;
  final String reference;
  final TradeStatus? status;
  final String? verificationHash;

  /// Tolerates the plain map used by older callers while the typed context
  /// stays the normal path.
  static SupportTradeContext? fromArguments(Object? arguments) {
    if (arguments is SupportTradeContext) return arguments;
    if (arguments is Map) {
      final id = arguments['supportTradeId'];
      final reference = arguments['supportTradeReference'];
      if (id is! String || reference is! String) return null;

      final statusName = arguments['supportTradeStatus'];
      TradeStatus? status;
      for (final value in TradeStatus.values) {
        if (value.name == statusName) {
          status = value;
          break;
        }
      }

      final hash = arguments['supportVerificationHash'];
      return SupportTradeContext(
        tradeId: id,
        reference: reference,
        status: status,
        verificationHash:
            hash is String && hash.trim().isNotEmpty ? hash : null,
      );
    }
    return null;
  }
}
