class AppConstants {
  AppConstants._();

  // Working name. Change the brand here and it updates everywhere.
  static const String appName = 'CrossPay';

  // Set at launch: flutter run --dart-define=API_BASE_URL=https://your-server
  // Empty means "not connected", and requests fail with a clear message.
  static const String apiBaseUrl = String.fromEnvironment('API_BASE_URL');
}
