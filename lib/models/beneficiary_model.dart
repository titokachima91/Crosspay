/// The two kinds of payout rail.
enum PayoutKind { mobileMoney, bank }

/// A destination payout rail (mobile money operator or bank transfer).
/// Supplied by the server (see AppConfig). Equality is by [id].
class PayoutRail {
  const PayoutRail({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.kind,
  });

  final String id;
  final String name;

  /// ISO country code the rail pays out in, e.g. used for the flag icon.
  final String countryCode;

  /// Decides how the account field is labelled and formatted.
  final PayoutKind kind;

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

enum AccountStatus { found, notFound }

enum NameMatch { match, mismatch, unavailable }

/// What the destination network says about an account and, once a name was
/// given, whether that name matches. The registered name itself is never sent.
class RecipientCheck {
  const RecipientCheck({
    required this.accountStatus,
    this.networkName,
    this.nameMatch,
  });

  final AccountStatus accountStatus;
  final String? networkName;

  /// Null when no name was supplied with the check.
  final NameMatch? nameMatch;
}

/// The recipient details a person has authorized paying.
class RecipientDetails {
  const RecipientDetails({
    required this.rail,
    required this.account,
    required this.name,
    required this.reference,
    required this.check,
  });

  final PayoutRail rail;

  /// International format for mobile money, as typed for banks.
  final String account;
  final String name;
  final String reference;
  final RecipientCheck check;

  bool sameAs(RecipientDetails other) =>
      rail == other.rail &&
      account == other.account &&
      name == other.name &&
      reference == other.reference;
}
