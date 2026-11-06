import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/trade_provider.dart';

// Test inputs only. Not app data.
const _rail = PayoutRail(
  id: 'r1',
  name: 'Test Rail',
  countryCode: 'ZZ',
  kind: PayoutKind.mobileMoney,
);

RecipientDetails _details({String reference = ''}) => RecipientDetails(
      rail: _rail,
      account: '+999712345678',
      name: 'Test Person',
      reference: reference,
      check: const RecipientCheck(accountStatus: AccountStatus.found),
    );

ProviderContainer _container() {
  var counter = 0;
  final container = ProviderContainer(overrides: [
    attemptKeyGeneratorProvider.overrideWithValue(() => 'key-${++counter}'),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('authorizing creates one key for the attempt', () {
    final container = _container();
    container.read(tradeProvider.notifier).authorize(_details(), quoteId: 'q1');

    final state = container.read(tradeProvider);
    expect(state.attemptKey, 'key-1');
    expect(state.recipient?.account, '+999712345678');
  });

  test('going back and authorizing the same thing again keeps the same key', () {
    final container = _container();
    final notifier = container.read(tradeProvider.notifier);

    notifier.authorize(_details(), quoteId: 'q1');
    notifier.authorize(_details(), quoteId: 'q1');

    expect(container.read(tradeProvider).attemptKey, 'key-1');
  });

  test('changed details or a new quote are a new attempt with a new key', () {
    final container = _container();
    final notifier = container.read(tradeProvider.notifier);

    notifier.authorize(_details(), quoteId: 'q1');
    notifier.authorize(_details(reference: 'invoice 7'), quoteId: 'q1');
    expect(container.read(tradeProvider).attemptKey, 'key-2');

    notifier.authorize(_details(reference: 'invoice 7'), quoteId: 'q2');
    expect(container.read(tradeProvider).attemptKey, 'key-3');
  });

  test('reset forgets the attempt', () {
    final container = _container();
    final notifier = container.read(tradeProvider.notifier);

    notifier.authorize(_details(), quoteId: 'q1');
    notifier.reset();

    final state = container.read(tradeProvider);
    expect(state.attemptKey, isNull);
    expect(state.recipient, isNull);
  });
}
