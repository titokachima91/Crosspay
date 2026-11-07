import 'package:crosspay_app/models/quote_model.dart';

enum TradeStatus {
  pendingDeposit,
  escrowed,
  matching,
  matched,
  disbursing,
  completed,
  expired,
  refunded,
  failed,
  cancelled,
}

/// Shared naming for a status: the server's own snake_case code (API and
/// timeline values) and the key for its plain-language label.
extension TradeStatusX on TradeStatus {
  String get code => switch (this) {
        TradeStatus.pendingDeposit => 'pending_deposit',
        TradeStatus.escrowed => 'escrowed',
        TradeStatus.matching => 'matching',
        TradeStatus.matched => 'matched',
        TradeStatus.disbursing => 'disbursing',
        TradeStatus.completed => 'completed',
        TradeStatus.expired => 'expired',
        TradeStatus.refunded => 'refunded',
        TradeStatus.failed => 'failed',
        TradeStatus.cancelled => 'cancelled',
      };

  /// Translation key for the label, e.g. 'trade.status.completed'.
  String get labelKey => 'trade.status.$code';
}

class Trade {
  const Trade({
    required this.id,
    required this.reference,
    required this.route,
    required this.status,
    required this.sendCurrency,
    required this.receiveCurrency,
    required this.sendAmountMinor,
    required this.feeMinor,
    required this.feeBps,
    required this.receiveAmountMinor,
    required this.rate,
    required this.beneficiaryName,
    required this.createdAt,
    this.verificationHash,
  });

  final String id;

  /// Order reference issued by the server. The app never builds one.
  final String reference;
  final RouteType route;
  final TradeStatus status;
  final Currency sendCurrency;
  final Currency receiveCurrency;
  final int sendAmountMinor;
  final int feeMinor;
  final int feeBps;
  final int receiveAmountMinor;

  /// Effective rate, for display on the receipt only.
  final double rate;
  final String beneficiaryName;
  final DateTime createdAt;
  final String? verificationHash;

  bool get isTerminal =>
      status == TradeStatus.completed ||
      status == TradeStatus.expired ||
      status == TradeStatus.refunded ||
      status == TradeStatus.failed ||
      status == TradeStatus.cancelled;

  Trade copyWith({TradeStatus? status, String? verificationHash}) {
    return Trade(
      id: id,
      reference: reference,
      route: route,
      status: status ?? this.status,
      sendCurrency: sendCurrency,
      receiveCurrency: receiveCurrency,
      sendAmountMinor: sendAmountMinor,
      feeMinor: feeMinor,
      feeBps: feeBps,
      receiveAmountMinor: receiveAmountMinor,
      rate: rate,
      beneficiaryName: beneficiaryName,
      createdAt: createdAt,
      verificationHash: verificationHash ?? this.verificationHash,
    );
  }
}

/// Invoice data returned by the server for sharing with QR code.
class Invoice {
  const Invoice({
    required this.tradeId,
    required this.qrCodeUrl,
    required this.shareUrl,
    required this.validUntil,
    required this.amount,
    required this.currency,
  });

  final String tradeId;
  final String qrCodeUrl;
  final String shareUrl;
  final DateTime validUntil;
  final int amount;
  final String currency;

  bool get isExpired => DateTime.now().isAfter(validUntil);
}

/// F4.1 — a one-time export link issued by the server. The app copies or
/// opens this link; it never assembles a file by itself.
class ExportTicket {
  const ExportTicket({required this.downloadUrl, required this.expiresAt});

  final String downloadUrl;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Manual payment details (Paybill / Till) from the server.
class ManualPayment {
  const ManualPayment({
    required this.methodCode,
    required this.number,
    required this.reference,
  });

  /// For example "paybill" or "till"; decides the label.
  final String methodCode;
  final String number;
  final String reference;
}

/// How the person pays for the trade: the prompt sent to their phone, the
/// timings, and the manual fallback. All of it comes from the server.
class CollectionInstructions {
  const CollectionInstructions({
    required this.pushSent,
    required this.amountMinor,
    required this.currency,
    required this.pushTimeoutSeconds,
    required this.pollIntervalSeconds,
    this.networkName,
    this.manual,
  });

  final bool pushSent;
  final String? networkName;

  /// The total to pay, in [currency] (the send currency).
  final int amountMinor;
  final Currency currency;

  /// When to open the manual fallback if nothing has happened yet.
  final int pushTimeoutSeconds;

  /// How often to check for the deposit.
  final int pollIntervalSeconds;
  final ManualPayment? manual;
}

class InitiatedTrade {
  const InitiatedTrade({required this.trade, required this.collection});

  final Trade trade;
  final CollectionInstructions collection;
}
