import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';

/// A country the app can register phone numbers for. Supplied by the server.
/// Equality is by [code].
class Country {
  const Country({
    required this.code,
    required this.name,
    required this.dialCode,
    required this.nationalNumberLength,
  });

  /// ISO country code, e.g. used for the flag.
  final String code;
  final String name;

  /// Calling code, digits only and without the plus sign.
  final String dialCode;

  /// How many digits a phone number has after the calling code and without
  /// any leading zero.
  final int nationalNumberLength;

  @override
  bool operator ==(Object other) => other is Country && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// A mobile network used to suggest the right mobile money provider.
/// Supplied by the server. Equality is by [id].
class Carrier {
  const Carrier({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.prefixPattern,
  });

  final String id;
  final String name;
  final String countryCode;

  /// Regular expression matched from the START of the national number
  /// (no calling code, no leading zero).
  final String prefixPattern;

  @override
  bool operator ==(Object other) => other is Carrier && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Reference data the server controls. Empty until the server has answered.
class AppConfig {
  const AppConfig({
    this.currencies = const [],
    this.hubs = const [],
    this.payoutRails = const [],
    this.countries = const [],
    this.carriers = const [],
  });

  final List<Currency> currencies;
  final List<TradingHub> hubs;
  final List<PayoutRail> payoutRails;
  final List<Country> countries;
  final List<Carrier> carriers;

  bool get isEmpty => currencies.isEmpty;

  Currency? currencyByCode(String code) {
    for (final c in currencies) {
      if (c.code == code) return c;
    }
    return null;
  }

  List<PayoutRail> railsForCountry(String countryCode) =>
      payoutRails.where((r) => r.countryCode == countryCode).toList();
}
