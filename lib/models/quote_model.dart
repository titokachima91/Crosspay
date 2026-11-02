/// A currency the platform supports. Supplied by the server (see AppConfig).
/// Equality is by [code].
class Currency {
  const Currency({
    required this.code,
    required this.name,
    required this.countryCode,
    required this.decimals,
  });

  final String code;
  final String name;

  /// Country the currency belongs to, used to draw the flag.
  final String countryCode;

  /// How many digits follow the decimal point on screen (for example 0 or 2).
  /// Amounts are whole numbers in the smallest unit: displayed value x 10^decimals.
  final int decimals;

  @override
  bool operator ==(Object other) => other is Currency && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// The two clearing routes the product offers (Screen 2.2).
enum RouteType { p2p, bank }

/// One route's outcome as priced by the server. Amounts are whole numbers in
/// the smallest unit of each currency (see Currency.decimals). The app displays
/// these values and never calculates them.
class RouteQuote {
  const RouteQuote({
    required this.route,
    required this.feeBps,
    required this.feeMinor,
    required this.payoutMinor,
    required this.totalDebitMinor,
    required this.estimatedMinSeconds,
    required this.estimatedMaxSeconds,
    required this.isRecommended,
    required this.isAvailable,
    this.matchingDensityPercent,
    this.status,
    this.safeguardCode,
    this.breakdown = const [],
  });

  final RouteType route;

  /// Fee rate in basis points (100 bps = 1%).
  final int feeBps;

  /// Platform fee, in the SEND currency.
  final int feeMinor;

  /// What the recipient receives, in the RECEIVE currency.
  final int payoutMinor;

  /// What the sender is charged in total, in the SEND currency.
  final int totalDebitMinor;

  final int estimatedMinSeconds;
  final int estimatedMaxSeconds;
  final bool isRecommended;
  final bool isAvailable;

  /// Peer-matching density (0 to 100), when the route has one.
  final int? matchingDensityPercent;

  /// Route health, as a code plus a level (like corridor status).
  final CorridorStatus? status;

  /// Present only when the safeguard really exists (for example an
  /// escrow partner). The app shows no safeguard claim without it.
  final String? safeguardCode;

  /// The fee lines that add up to [feeMinor], in the SEND currency.
  final List<FeeLine> breakdown;
}

/// A server-issued price with a rate lock that ends at [expiresAt].
class Quote {
  const Quote({
    required this.id,
    required this.sendCurrency,
    required this.receiveCurrency,
    required this.sendAmountMinor,
    required this.rate,
    required this.expiresAt,
    required this.routes,
    this.clockOffset = Duration.zero,
  });

  final String id;
  final Currency sendCurrency;
  final Currency receiveCurrency;
  final int sendAmountMinor;

  /// Units of send currency per 1 unit of receive currency.
  /// For display only. Never used to calculate money in the app.
  final double rate;

  final DateTime expiresAt;
  final List<RouteQuote> routes;

  /// Server clock minus phone clock when the quote arrived. Keeps a wrong
  /// phone clock from stretching or cutting the rate lock.
  final Duration clockOffset;

  Duration remainingAt(DateTime now) {
    final diff = expiresAt.difference(now.add(clockOffset));
    return diff.isNegative ? Duration.zero : diff;
  }

  bool isExpiredAt(DateTime now) => remainingAt(now) == Duration.zero;

  RouteQuote? forRoute(RouteType type) {
    for (final r in routes) {
      if (r.route == type) return r;
    }
    return null;
  }

  /// The route to preselect: the recommended one if available, otherwise the
  /// first available one, otherwise none.
  RouteQuote? get defaultRoute {
    for (final r in routes) {
      if (r.isAvailable && r.isRecommended) return r;
    }
    for (final r in routes) {
      if (r.isAvailable) return r;
    }
    return null;
  }
}

/// How healthy a corridor is, used for the coloured status dot.
enum CorridorLevel { healthy, limited, down }

/// A corridor's status: a server code (translated by the app when known)
/// plus a level for the dot colour.
class CorridorStatus {
  const CorridorStatus({required this.code, required this.level});

  final String code;
  final CorridorLevel level;
}

/// A live market rate (Screens 1.1 and 4.1).
class CorridorRate {
  const CorridorRate({
    required this.from,
    required this.to,
    required this.rate,
    this.change24hPercent,
    this.status,
  });

  final Currency from;
  final Currency to;

  /// How many [from] units equal one [to] unit (display only).
  final double rate;
  final double? change24hPercent;
  final CorridorStatus? status;
}

/// An indicative conversion shown while typing. It is NOT a locked price: the
/// real, locked quote comes later with the route choice.
class Estimate {
  const Estimate({
    required this.rate,
    required this.receiveAmountMinor,
    required this.estimatedMinSeconds,
    required this.estimatedMaxSeconds,
    required this.route,
  });

  /// Units of send currency per 1 unit of receive currency (display only).
  final double rate;

  /// What the recipient would get (fees are added on top, never deducted).
  final int receiveAmountMinor;

  final int estimatedMinSeconds;
  final int estimatedMaxSeconds;
  final RouteType route;
}

/// One line of a route's fee breakdown (for example the platform fee).
class FeeLine {
  const FeeLine({required this.code, required this.amountMinor});

  final String code;

  /// In the SEND currency.
  final int amountMinor;
}
