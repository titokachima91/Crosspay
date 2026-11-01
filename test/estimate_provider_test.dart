import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

Estimate _estimate(int receive) => Estimate(
      rate: 2,
      receiveAmountMinor: receive,
      estimatedMinSeconds: 1800,
      estimatedMaxSeconds: 7200,
      route: RouteType.p2p,
    );

class _FakeTradeRepository extends TradeRepository {
  _FakeTradeRepository(this._handler) : super(Dio());

  final Future<Estimate> Function(int sendAmountMinor) _handler;

  @override
  Future<Estimate> estimate({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) =>
      _handler(sendAmountMinor);
}

ProviderContainer _container(_FakeTradeRepository repo) {
  final container = ProviderContainer(overrides: [
    tradeRepositoryProvider.overrideWithValue(repo),
    estimateDebounceProvider.overrideWithValue(Duration.zero),
  ]);
  addTearDown(container.dispose);
  container.read(estimateProvider); // start listening to the inputs
  return container;
}

void _setInputs(ProviderContainer container, int amount) {
  final quote = container.read(quoteProvider.notifier);
  quote.setSendCurrency(_a);
  quote.setReceiveCurrency(_b);
  quote.setSendAmount(amount);
}

void main() {
  test('an estimate is fetched once the inputs are valid', () async {
    final container = _container(
      _FakeTradeRepository((amount) async => _estimate(amount * 50)),
    );

    _setInputs(container, 1000);
    await pumpEventQueue();

    final state = container.read(estimateProvider);
    expect(state.status, EstimateStatus.ready);
    expect(state.estimate?.receiveAmountMinor, 50000);
  });

  test('inputs that become invalid clear the estimate', () async {
    final container = _container(
      _FakeTradeRepository((amount) async => _estimate(amount)),
    );

    _setInputs(container, 1000);
    await pumpEventQueue();
    container.read(quoteProvider.notifier).setSendAmount(0);
    await pumpEventQueue();

    final state = container.read(estimateProvider);
    expect(state.status, EstimateStatus.idle);
    expect(state.estimate, isNull);
  });

  test('a failure reports a translatable key', () async {
    final container = _container(
      _FakeTradeRepository(
        (amount) async => throw const ApiException(kind: ApiErrorKind.network),
      ),
    );

    _setInputs(container, 1000);
    await pumpEventQueue();

    final state = container.read(estimateProvider);
    expect(state.status, EstimateStatus.error);
    expect(state.errorKey, 'error.network');
  });

  test('an older slow answer never overwrites a newer one', () async {
    final slowFirst = Completer<Estimate>();
    final container = _container(
      _FakeTradeRepository(
        (amount) => amount == 1000
            ? slowFirst.future
            : Future<Estimate>.value(_estimate(777)),
      ),
    );

    _setInputs(container, 1000);
    await pumpEventQueue(); // request for 1000 is still on its way

    container.read(quoteProvider.notifier).setSendAmount(2000);
    await pumpEventQueue(); // request for 2000 has answered

    slowFirst.complete(_estimate(111)); // the old answer arrives late
    await pumpEventQueue();

    expect(container.read(estimateProvider).estimate?.receiveAmountMinor, 777);
  });
}
