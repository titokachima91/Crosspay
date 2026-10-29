import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/rates_provider.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

// Test stand-ins only. Not app code.
class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository(this._outcome) : super(Dio());

  final Future<AppConfig> Function() _outcome;

  @override
  Future<AppConfig> fetch() => _outcome();
}

class _FakeRatesRepository extends RatesRepository {
  _FakeRatesRepository(this._outcome) : super(Dio());

  final Future<RatesSnapshot> Function() _outcome;

  @override
  Future<RatesSnapshot> fetch(AppConfig config) => _outcome();
}

const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ');
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ');

void main() {
  test('config loads and becomes ready', () async {
    final container = ProviderContainer(overrides: [
      configRepositoryProvider.overrideWithValue(
        _FakeConfigRepository(
          () async => const AppConfig(currencies: [_a, _b]),
        ),
      ),
    ]);
    addTearDown(container.dispose);

    await container.read(appConfigProvider.notifier).load();

    final state = container.read(appConfigProvider);
    expect(state.status, ConfigStatus.ready);
    expect(state.config.currencies.length, 2);
  });

  test('a failed config load reports a translatable error key', () async {
    final container = ProviderContainer(overrides: [
      configRepositoryProvider.overrideWithValue(
        _FakeConfigRepository(
          () async => throw const ApiException(kind: ApiErrorKind.network),
        ),
      ),
    ]);
    addTearDown(container.dispose);

    await container.read(appConfigProvider.notifier).load();

    final state = container.read(appConfigProvider);
    expect(state.status, ConfigStatus.error);
    expect(state.errorKey, 'error.network');
  });

  test('rates stay unavailable until the config has loaded', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(ratesProvider.notifier).load();

    expect(container.read(ratesProvider).status, RatesStatus.unavailable);
  });

  test('rates load once config is ready, and failures clear old rates', () async {
    var failNext = false;
    final container = ProviderContainer(overrides: [
      configRepositoryProvider.overrideWithValue(
        _FakeConfigRepository(
          () async => const AppConfig(currencies: [_a, _b]),
        ),
      ),
      ratesRepositoryProvider.overrideWithValue(
        _FakeRatesRepository(() async {
          if (failNext) {
            throw const ApiException(kind: ApiErrorKind.timeout);
          }
          return const RatesSnapshot(
            rates: [CorridorRate(from: _a, to: _b, rate: 2.0)],
            p2pDensityPercent: 10,
          );
        }),
      ),
    ]);
    addTearDown(container.dispose);

    await container.read(appConfigProvider.notifier).load();
    await container.read(ratesProvider.notifier).load();

    var state = container.read(ratesProvider);
    expect(state.status, RatesStatus.live);
    expect(state.rates.length, 1);
    expect(state.p2pDensityPercent, 10);

    failNext = true;
    await container.read(ratesProvider.notifier).load();

    state = container.read(ratesProvider);
    expect(state.status, RatesStatus.error);
    expect(state.rates, isEmpty);
    expect(state.errorKey, 'error.timeout');
  });
}
