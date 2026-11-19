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

/// Optional support channels the server controls. Every field is optional so
/// the app can ship before a support desk is connected.
class SupportInfo {
  const SupportInfo({
    this.email,
    this.phone,
    this.whatsapp,
    this.hours,
  });

  final String? email;
  final String? phone;
  final String? whatsapp;
  final String? hours;

  bool get hasChannels => _has(email) || _has(phone) || _has(whatsapp);

  bool get isEmpty => !hasChannels && !_has(hours);

  static bool _has(String? value) => value != null && value.trim().isNotEmpty;
}

/// Emergency service state published by the server. Null means normal.
class ServiceStatus {
  const ServiceStatus({
    required this.quotesPaused,
    required this.tradesPaused,
    this.message,
  });

  final bool quotesPaused;
  final bool tradesPaused;
  final String? message;

  bool get isActive =>
      quotesPaused ||
      tradesPaused ||
      (message != null && message!.trim().isNotEmpty);
}

enum BannerSeverity { info, warning, critical }

/// A published, scheduled message from the server. Both languages are
/// authored and approved in the admin portal; the app only chooses which one
/// to show and never writes banner text itself.
class AppBanner {
  const AppBanner({
    required this.id,
    required this.messageEn,
    required this.messageSw,
    required this.severity,
    required this.startsAt,
    required this.endsAt,
  });

  final String id;
  final String messageEn;
  final String messageSw;
  final BannerSeverity severity;

  /// Start of the published window, inclusive.
  final DateTime startsAt;

  /// End of the published window, exclusive.
  final DateTime endsAt;

  bool isActiveAt(DateTime now) =>
      !now.isBefore(startsAt) && now.isBefore(endsAt);

  /// Falls back to English for any language the server did not provide.
  String messageFor(String localeCode) =>
      localeCode == 'sw' && messageSw.trim().isNotEmpty ? messageSw : messageEn;
}

/// Reference data the server controls. Empty until the server has answered.
class AppConfig {
  const AppConfig({
    this.currencies = const [],
    this.hubs = const [],
    this.payoutRails = const [],
    this.countries = const [],
    this.carriers = const [],
    this.support,
    this.banners = const [],
    this.service,
  });

  final List<Currency> currencies;
  final List<TradingHub> hubs;
  final List<PayoutRail> payoutRails;
  final List<Country> countries;
  final List<Carrier> carriers;

  /// Support channels, when the server publishes them. Null means the support
  /// block has not been configured yet.
  final SupportInfo? support;

  /// Published banners whose window was open when `/config` was fetched. The
  /// server filters by window; the app checks the window again before showing.
  final List<AppBanner> banners;

  /// Emergency quote/trade pause or maintenance message, when active.
  final ServiceStatus? service;

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
