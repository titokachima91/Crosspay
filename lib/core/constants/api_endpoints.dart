/// REST paths. Only endpoints that are agreed are listed here.
class ApiEndpoints {
  ApiEndpoints._();

  static const String _v1 = '/api/v1';

  static const String tradeQuote = '$_v1/trade/quote';
  static const String tradeInitiate = '$_v1/trade/initiate';
}
