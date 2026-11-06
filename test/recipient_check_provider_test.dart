import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/recipient_check_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _rail = PayoutRail(
  id: 'r1',
  name: 'Test Rail',
  countryCode: 'ZZ',
  kind: PayoutKind.mobileMoney,
);

class _FakeBeneficiaryRepository extends BeneficiaryRepository {
  _FakeBeneficiaryRepository(this._handler) : super(Dio());

  final Future<RecipientCheck> Function(String account, String? name) _handler;
  int calls = 0;

  @override
  Future<RecipientCheck> check({
    required PayoutRail rail,
    required String account,
    String? name,
  }) {
    calls++;
    return _handler(account, name);
  }
}

ProviderContainer _container(_FakeBeneficiaryRepository repo) {
  final container = ProviderContainer(overrides: [
    beneficiaryRepositoryProvider.overrideWithValue(repo),
    recipientCheckDebounceProvider.overrideWithValue(Duration.zero),
  ]);
  addTearDown(container.dispose);
  container.read(recipientCheckProvider);
  return container;
}

RecipientCheck _found(String? name) => RecipientCheck(
      accountStatus: AccountStatus.found,
      networkName: 'Test Network',
      nameMatch: name == null ? null : NameMatch.match,
    );

void main() {
  test('a complete account is checked once typing pauses', () async {
    final repo = _FakeBeneficiaryRepository((account, name) async => _found(name));
    final container = _container(repo);

    container.read(recipientCheckProvider.notifier).inputsChanged(
          rail: _rail,
          account: '+999712345678',
          accountReady: true,
          name: '',
        );
    expect(
      container.read(recipientCheckProvider).status,
      RecipientCheckStatus.loading,
    );
    await pumpEventQueue();

    final state = container.read(recipientCheckProvider);
    expect(state.status, RecipientCheckStatus.ready);
    expect(state.check?.networkName, 'Test Network');
    expect(state.check?.nameMatch, isNull);
  });

  test('an incomplete account asks the server nothing', () async {
    final repo = _FakeBeneficiaryRepository((account, name) async => _found(name));
    final container = _container(repo);

    container.read(recipientCheckProvider.notifier).inputsChanged(
          rail: _rail,
          account: '+99971',
          accountReady: false,
          name: 'Test Person',
        );
    await pumpEventQueue();

    expect(repo.calls, 0);
    expect(container.read(recipientCheckProvider).status, RecipientCheckStatus.idle);
  });

  test('the name is sent only when one was typed', () async {
    String? sentName = 'unset';
    final repo = _FakeBeneficiaryRepository((account, name) async {
      sentName = name;
      return _found(name);
    });
    final container = _container(repo);
    final notifier = container.read(recipientCheckProvider.notifier);

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345678',
      accountReady: true,
      name: '',
    );
    await pumpEventQueue();
    expect(sentName, isNull);

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345678',
      accountReady: true,
      name: 'Test Person',
    );
    await pumpEventQueue();
    expect(sentName, 'Test Person');
  });

  test('editing clears the old answer immediately', () async {
    final repo = _FakeBeneficiaryRepository((account, name) async => _found(name));
    final container = _container(repo);
    final notifier = container.read(recipientCheckProvider.notifier);

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345678',
      accountReady: true,
      name: 'Test Person',
    );
    await pumpEventQueue();
    expect(container.read(recipientCheckProvider).check, isNotNull);

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345679',
      accountReady: true,
      name: 'Test Person',
    );
    expect(container.read(recipientCheckProvider).check, isNull);
  });

  test('a failure reports a translatable key', () async {
    final repo = _FakeBeneficiaryRepository(
      (account, name) async => throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 429,
        code: 'RATE_LIMITED',
      ),
    );
    final container = _container(repo);

    container.read(recipientCheckProvider.notifier).inputsChanged(
          rail: _rail,
          account: '+999712345678',
          accountReady: true,
          name: '',
        );
    await pumpEventQueue();

    final state = container.read(recipientCheckProvider);
    expect(state.status, RecipientCheckStatus.error);
    expect(state.errorKey, 'error.client');
    expect(state.errorCode, 'RATE_LIMITED');
  });

  test('an older slow answer never overwrites a newer one', () async {
    final slowFirst = Completer<RecipientCheck>();
    final repo = _FakeBeneficiaryRepository(
      (account, name) => account.endsWith('1')
          ? slowFirst.future
          : Future<RecipientCheck>.value(_found(name)),
    );
    final container = _container(repo);
    final notifier = container.read(recipientCheckProvider.notifier);

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345671',
      accountReady: true,
      name: '',
    );
    await pumpEventQueue(); // request for ...1 is still on its way

    notifier.inputsChanged(
      rail: _rail,
      account: '+999712345672',
      accountReady: true,
      name: '',
    );
    await pumpEventQueue(); // request for ...2 has answered

    slowFirst.complete(
      const RecipientCheck(accountStatus: AccountStatus.notFound),
    );
    await pumpEventQueue(); // the old answer arrives late

    expect(
      container.read(recipientCheckProvider).check?.accountStatus,
      AccountStatus.found,
    );
  });
}
