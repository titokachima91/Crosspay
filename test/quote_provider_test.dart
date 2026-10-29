import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/quote_provider.dart';

// Test inputs only. Not app data.
const _a = Currency(code: 'AAA', name: 'Test currency A');
const _b = Currency(code: 'BBB', name: 'Test currency B');

RouteQuote _route(
  RouteType type, {
  bool recommended = false,
  bool available = true,
}) =>
    RouteQuote(
      route: type,
      feeBps: 0,
      feeMinor: 0,
      payoutMinor: 0,
      totalDebitMinor: 0,
      estimatedMinSeconds: 0,
      estimatedMaxSeconds: 0,
      isRecommended: recommended,
      isAvailable: available,
    );

Quote _quote(DateTime expiresAt, {List<RouteQuote> routes = const []}) => Quote(
      id: 'test-quote',
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
      rate: 2.0,
      expiresAt: expiresAt,
      routes: routes,
    );

DateTime _later() => DateTime.now().add(const Duration(seconds: 60));

void main() {
  test('quote reports remaining time and expiry correctly', () {
    final now = DateTime(2026, 1, 1, 10, 0, 0);
    final q = _quote(now.add(const Duration(seconds: 100)));

    expect(q.remainingAt(now), const Duration(seconds: 100));
    expect(q.isExpiredAt(now), false);
    expect(q.isExpiredAt(now.add(const Duration(seconds: 100))), true);
    expect(q.isExpiredAt(now.add(const Duration(seconds: 101))), true);
  });

  test('a fresh quote becomes ready, then reset returns to idle', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(quoteProvider.notifier);

    notifier.quoteReceived(_quote(_later()));
    final state = container.read(quoteProvider);
    expect(state.status, QuoteStatus.ready);
    expect(state.remaining.inSeconds, greaterThan(55));

    notifier.reset();
    expect(container.read(quoteProvider).status, QuoteStatus.idle);
  });

  test('an already-expired quote is marked expired immediately', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(quoteProvider.notifier).quoteReceived(
          _quote(DateTime.now().subtract(const Duration(seconds: 5))),
        );

    expect(container.read(quoteProvider).status, QuoteStatus.expired);
  });

  test('the server-recommended route is preselected', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(quoteProvider.notifier);

    notifier.quoteReceived(_quote(_later(), routes: [
      _route(RouteType.bank),
      _route(RouteType.p2p, recommended: true),
    ]));
    expect(container.read(quoteProvider).selectedRoute, RouteType.p2p);

    notifier.selectRoute(RouteType.bank);
    expect(container.read(quoteProvider).selectedRoute, RouteType.bank);
  });

  test('an unavailable route can never be selected', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(quoteProvider.notifier);

    notifier.quoteReceived(_quote(_later(), routes: [
      _route(RouteType.bank),
      _route(RouteType.p2p, recommended: true, available: false),
    ]));
    expect(container.read(quoteProvider).selectedRoute, RouteType.bank);

    notifier.selectRoute(RouteType.p2p);
    expect(container.read(quoteProvider).selectedRoute, RouteType.bank);
  });

  test('changing the amount invalidates the quote', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(quoteProvider.notifier);

    notifier.quoteReceived(_quote(_later()));
    notifier.setSendAmount(2000);

    final state = container.read(quoteProvider);
    expect(state.quote, isNull);
    expect(state.status, QuoteStatus.idle);
    expect(state.sendAmountMinor, 2000);
  });
}
