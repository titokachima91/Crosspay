import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';

/// Reference data the server controls: which currencies, hubs and payout
/// rails are enabled. Empty until the server has answered.
class AppConfig {
  const AppConfig({
    this.currencies = const [],
    this.hubs = const [],
    this.payoutRails = const [],
  });

  final List<Currency> currencies;
  final List<TradingHub> hubs;
  final List<PayoutRail> payoutRails;

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
