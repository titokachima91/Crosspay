/// REST paths. Only endpoints that are agreed are listed here.
/// The agreed shapes are written down in docs/api_contract.md.
class ApiEndpoints {
  ApiEndpoints._();

  static const String _v1 = '/api/v1';

  static const String config = '$_v1/config';
  static const String rates = '$_v1/rates';
  static const String otpRequest = '$_v1/auth/otp/request';
  static const String otpVerify = '$_v1/auth/otp/verify';
  static const String kyc = '$_v1/me/kyc';
  static const String me = '$_v1/me';
  static const String beneficiaries = '$_v1/beneficiaries';
  static const String beneficiaryCheck = '$_v1/beneficiaries/check';
  static const String tradeEstimate = '$_v1/trade/estimate';
  static const String tradeQuote = '$_v1/trade/quote';
  static const String tradeInitiate = '$_v1/trade/initiate';

  static const String trades = '$_v1/trades';

  /// F4.1 — one-time CSV export link. Registered before [trade] so the
  /// literal path is never mistaken for a trade id on the server.
  static const String tradesExport = '$_v1/trades/export';

  /// F4.1 — spending analytics aggregated by the server.
  static const String tradesAnalytics = '$_v1/trades/analytics';

  /// F4.2 — queue depth and health per corridor.
  static const String marketDepth = '$_v1/market/depth';

  static String trade(String id) => '$_v1/trades/${Uri.encodeComponent(id)}';
  static String tradePaymentClaim(String id) => '${trade(id)}/payment-claim';
  static String tradeCancel(String id) => '${trade(id)}/cancel';
  static String tradeInvoice(String id) => '${trade(id)}/invoice';
  static String tradeShare(String id) => '${trade(id)}/share';

  /// F4.1 — the status change timeline of one trade.
  static String tradeHistory(String id) => '${trade(id)}/history';

  /// F5.2 — one saved recipient: GET (single), PATCH (edit), DELETE (remove).
  static String beneficiary(String id) =>
      '$_v1/beneficiaries/${Uri.encodeComponent(id)}';
}
