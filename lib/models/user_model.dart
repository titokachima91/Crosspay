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
    this.nationalIdOrTin,
  });

  final String id;
  final String phone;
  final String businessName;
  final TradingHub hub;
  final KycStatus kycStatus;
  final String? nationalIdOrTin;

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
