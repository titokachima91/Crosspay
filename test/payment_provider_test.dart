import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/payment_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

import 'support/payment_fakes.dart';

ProviderContainer _ready(FakeTradeRepository repo) {
  final container = ProviderContainer(overrides: [
    tradeRepositoryProvider.overrideWithValue(repo),
    // The server's seconds become milliseconds, so the tests run fast.
    paymentDurationProvider
        .overrideWithValue((seconds) => Duration(milliseconds: seconds)),
    attemptKeyGeneratorProvider.overrideWithValue(() => 'key-1'),
  ]);
  addTearDown(container.dispose);

  container.read(quoteProvider.notifier).quoteReceived(fakeQuote());
  container
      .read(tradeProvider.notifier)
      .authorize(fakeRecipient(), quoteId: 'q1');
  return container;
}

Future<void> _wait(int milliseconds) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

void main() {
  test('starting sends the attempt key once and begins waiting', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();

    final state = container.read(paymentProvider);
    expect(state.status, PaymentStatus.waiting);
    expect(state.fallbackOpen, false);
    expect(repo.lastKey, 'key-1');
    expect(repo.lastQuoteId, 'q1');
    expect(repo.lastRoute, RouteType.p2p);
    expect(repo.lastRecipient?.account, '+888712345678');
    expect(container.read(tradeProvider).activeTrade?.id, 't1');
  });

  test('starting again for the same attempt never starts a second payment', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);
    final notifier = container.read(paymentProvider.notifier);

    await notifier.start();
    await notifier.start();

    expect(repo.initiateCalls, 1);
  });

  test('the deposit arriving moves to paid and stops the checks', () async {
    var checks = 0;
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => checks++ < 2
          ? fakeTrade(TradeStatus.pendingDeposit)
          : fakeTrade(TradeStatus.escrowed),
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();
    await _wait(150);

    expect(container.read(paymentProvider).status, PaymentStatus.paid);
    expect(container.read(tradeProvider).activeTrade?.status, TradeStatus.escrowed);

    final callsWhenPaid = repo.fetchCalls;
    await _wait(60);
    expect(repo.fetchCalls, callsWhenPaid);
  });

  test('an expired payment is reported as not completed', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.expired),
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();
    await _wait(100);

    expect(container.read(paymentProvider).status, PaymentStatus.notCompleted);
  });

  test('the manual fallback opens after the push timeout', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();
    expect(container.read(paymentProvider).fallbackOpen, false);

    await _wait(120);
    expect(container.read(paymentProvider).fallbackOpen, true);
  });

  test('without a prompt the manual fallback is open at once', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(pushSent: false),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();

    expect(container.read(paymentProvider).fallbackOpen, true);
  });

  test('a failed start reports a translatable error and can be retried with the same key', () async {
    var attempts = 0;
    final repo = FakeTradeRepository(
      onInitiate: () async {
        attempts++;
        if (attempts == 1) {
          throw const ApiException(
            kind: ApiErrorKind.client,
            statusCode: 422,
            code: 'QUOTE_EXPIRED',
          );
        }
        return fakeInitiated();
      },
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);
    final notifier = container.read(paymentProvider.notifier);

    await notifier.start();
    var state = container.read(paymentProvider);
    expect(state.status, PaymentStatus.error);
    expect(state.errorKey, 'error.client');
    expect(state.errorCode, 'QUOTE_EXPIRED');

    await notifier.start();
    state = container.read(paymentProvider);
    expect(state.status, PaymentStatus.waiting);
    expect(repo.initiateCalls, 2);
    expect(repo.lastKey, 'key-1');
  });

  test('missing details are reported instead of starting', () async {
    final container = ProviderContainer(overrides: [
      tradeRepositoryProvider.overrideWithValue(FakeTradeRepository()),
    ]);
    addTearDown(container.dispose);

    await container.read(paymentProvider.notifier).start();

    final state = container.read(paymentProvider);
    expect(state.status, PaymentStatus.error);
    expect(state.errorKey, 'collect.missing_details');
  });

  test('a hiccup while checking is noted and the payment keeps waiting', () async {
    var calls = 0;
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () {
        calls++;
        if (calls == 1) {
          throw const ApiException(kind: ApiErrorKind.network);
        }
        return Completer<Trade>().future; // the next check never answers
      },
    );
    final container = _ready(repo);

    await container.read(paymentProvider.notifier).start();
    await _wait(80);

    final state = container.read(paymentProvider);
    expect(state.status, PaymentStatus.waiting);
    expect(state.pollErrorKey, 'error.network');
  });

  test('claiming a manual payment tells the server and keeps checking', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = _ready(repo);
    final notifier = container.read(paymentProvider.notifier);

    await notifier.start();
    await notifier.claimManualPayment();
    await notifier.claimManualPayment(); // a second tap does nothing

    final state = container.read(paymentProvider);
    expect(repo.claimCalls, 1);
    expect(state.claimSent, true);
    expect(state.status, PaymentStatus.waiting);
  });

  test('cancelling ends the flow and forgets the attempt', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
      onCancel: () async => fakeTrade(TradeStatus.cancelled),
    );
    final container = _ready(repo);
    final notifier = container.read(paymentProvider.notifier);

    await notifier.start();
    final ended = await notifier.cancel();

    expect(ended, true);
    expect(repo.cancelCalls, 1);
    expect(container.read(paymentProvider).status, PaymentStatus.idle);
    expect(container.read(tradeProvider).attemptKey, isNull);
  });

  test('a refused cancel keeps the payment going and says why', () async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
      onCancel: () async => throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 409,
        code: 'CANNOT_CANCEL',
      ),
    );
    final container = _ready(repo);
    final notifier = container.read(paymentProvider.notifier);

    await notifier.start();
    final ended = await notifier.cancel();

    final state = container.read(paymentProvider);
    expect(ended, false);
    expect(state.status, PaymentStatus.waiting);
    expect(state.actionErrorCode, 'CANNOT_CANCEL');
  });
}
