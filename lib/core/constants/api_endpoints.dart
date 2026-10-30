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
  static const String tradeQuote = '$_v1/trade/quote';
  static const String tradeInitiate = '$_v1/trade/initiate';
}
