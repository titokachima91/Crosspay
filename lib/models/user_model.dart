import 'package:crosspay_app/models/quote_model.dart';

enum KycStatus { notStarted, pending, verified, rejected }

/// A trading market the merchant can register under (Screen 1.4 dropdown).
/// Supplied by the server (see AppConfig). Equality is by [id].
class TradingHub {
  const TradingHub({
    required this.id,
    required this.name,
    required this.countryCode,
  });

  final String id;
  final String name;
  final String countryCode;

  @override
  bool operator ==(Object other) => other is TradingHub && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.phone,
    required this.businessName,
    required this.hub,
    required this.kycStatus,
    required this.limitCurrency,
    required this.dailyLimitMinor,
    required this.dailyUsedMinor,
  });

  final String id;
  final String phone;
  final String businessName;
  final TradingHub hub;
  final KycStatus kycStatus;

  /// Daily limit and usage for the Screen 5.1 capacity bar, in minor units
  /// of [limitCurrency].
  final Currency limitCurrency;
  final int dailyLimitMinor;
  final int dailyUsedMinor;

  bool get isVerified => kycStatus == KycStatus.verified;

  double get dailyUsedFraction {
    if (dailyLimitMinor <= 0) return 0;
    return (dailyUsedMinor / dailyLimitMinor).clamp(0.0, 1.0).toDouble();
  }
}

/// The server's answer to "send me a verification code". All timings come
/// from the server; [requestedAt] is when the app received the answer.
class OtpChallenge {
  const OtpChallenge({
    required this.codeLength,
    required this.resendAfterSeconds,
    required this.expiresInSeconds,
    required this.requestedAt,
  });

  final int codeLength;
  final int resendAfterSeconds;
  final int expiresInSeconds;
  final DateTime requestedAt;

  DateTime get resendAvailableAt =>
      requestedAt.add(Duration(seconds: resendAfterSeconds));

  DateTime get expiresAt => requestedAt.add(Duration(seconds: expiresInSeconds));
}

/// The server's answer to a correct verification code.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.profileComplete,
  });

  final String accessToken;

  /// False for a new merchant who still has to complete business KYC.
  final bool profileComplete;
}
