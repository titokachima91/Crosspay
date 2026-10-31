/// A destination payout rail (mobile money operator or bank transfer).
/// Supplied by the server (see AppConfig). Equality is by [id].
class PayoutRail {
  const PayoutRail({
    required this.id,
    required this.name,
    required this.countryCode,
  });

  final String id;
  final String name;

  /// ISO country code the rail pays out in, e.g. used for the flag icon.
  final String countryCode;

  @override
  bool operator ==(Object other) => other is PayoutRail && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class Beneficiary {
  const Beneficiary({
    required this.id,
    required this.name,
    required this.rail,
    required this.accountOrPhone,
    this.kycVerified = false,
  });

  final String id;
  /// The recipient's name: a person or a business.
  final String name;
  final PayoutRail rail;

  /// Mobile number or bank account number, depending on [rail].
  final String accountOrPhone;

  /// True once the destination network confirmed the name matches.
  final bool kycVerified;

  String get countryCode => rail.countryCode;
}
