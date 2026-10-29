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
      status == TradeStatus.failed;

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
