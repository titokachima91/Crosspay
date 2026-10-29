class AppConstants {
  AppConstants._();

  // Working name. Change the brand here and it updates everywhere.
  static const String appName = 'CrossPay';

  // Business rules from the whitepaper
  static const Duration rateLockDuration = Duration(seconds: 300);
  static const Duration p2pQueueSla = Duration(hours: 2);
}
