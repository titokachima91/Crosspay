import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

RouteQuote _route(RouteType type, {bool recommended = false}) => RouteQuote(
      route: type,
      feeBps: 0,
      feeMinor: 0,
      payoutMinor: 0,
      totalDebitMinor: 0,
      estimatedMinSeconds: 0,
      estimatedMaxSeconds: 0,
      isRecommended: recommended,
      isAvailable: true,
    );

Quote _quote(String id) => Quote(
      id: id,
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
      rate: 2,
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
      routes: [_route(RouteType.bank), _route(RouteType.p2p, recommended: true)],
    );

class _FakeTradeRepository extends TradeRepository {
  _FakeTradeRepository(this._handler) : super(Dio());

  final Future<Quote> Function(int sendAmountMinor) _handler;

  @override
  Future<Quote> quote({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) =>
      _handler(sendAmountMinor);
}

ProviderContainer _container(_FakeTradeRepository repo, {int amount = 1000}) {
  final container = ProviderContainer(overrides: [
    tradeRepositoryProvider.overrideWithValue(repo),
  ]);
  addTearDown(container.dispose);
  container.read(quoteProvider.notifier)
    ..setSendCurrency(_a)
    ..setReceiveCurrency(_b)
    ..setSendAmount(amount);
  return container;
}

void main() {
  test('a quote is requested, stored, and the recommended route preselected', () async {
    final container = _container(
      _FakeTradeRepository((amount) async => _quote('q1')),
    );

    await container.read(quoteProvider.notifier).requestQuote();

    final state = container.read(quoteProvider);
    expect(state.status, QuoteStatus.ready);
    expect(state.quote?.id, 'q1');
    expect(state.selectedRoute, RouteType.p2p);
    expect(state.remaining.inSeconds, greaterThan(55));
  });

  test('a failure reports a translatable key and the server code', () async {
    final container = _container(
      _FakeTradeRepository(
        (amount) async => throw const ApiException(
          kind: ApiErrorKind.client,
          statusCode: 422,
          code: 'LIMIT_EXCEEDED',
        ),
      ),
    );

    await container.read(quoteProvider.notifier).requestQuote();

    final state = container.read(quoteProvider);
    expect(state.status, QuoteStatus.error);
    expect(state.errorKey, 'error.client');
    expect(state.errorCode, 'LIMIT_EXCEEDED');
  });

  test('nothing is requested without a valid amount', () async {
    final container = _container(
      _FakeTradeRepository((amount) async => _quote('q1')),
      amount: 0,
    );

    await container.read(quoteProvider.notifier).requestQuote();

    expect(container.read(quoteProvider).status, QuoteStatus.idle);
  });

  test('an older slow answer never overwrites a newer quote', () async {
    final slowFirst = Completer<Quote>();
    final container = _container(
      _FakeTradeRepository(
        (amount) => amount == 1000
            ? slowFirst.future
            : Future<Quote>.value(_quote('second')),
      ),
    );
    final notifier = container.read(quoteProvider.notifier);

    final first = notifier.requestQuote(); // still on its way
    notifier.setSendAmount(2000); // the person changed the amount
    await notifier.requestQuote();
    expect(container.read(quoteProvider).quote?.id, 'second');

    slowFirst.complete(_quote('first')); // the old answer arrives late
    await first;

    expect(container.read(quoteProvider).quote?.id, 'second');
  });
}
