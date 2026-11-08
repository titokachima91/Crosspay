import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/market_depth_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/market_depth_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _tzs = Currency(
  code: 'TZS',
  name: 'Tanzanian Shilling',
  countryCode: 'TZ',
  decimals: 0,
);
const _kes = Currency(
  code: 'KES',
  name: 'Kenyan Shilling',
  countryCode: 'KE',
  decimals: 2,
);
const _config = AppConfig(currencies: [_tzs, _kes]);

class _ReadyConfig extends ConfigNotifier {
  _ReadyConfig(this._state);

  final ConfigState _state;

  @override
  ConfigState build() => _state;
}

class _FakeRatesRepository extends RatesRepository {
  _FakeRatesRepository(this._answer) : super(Dio());

  final Future<List<CorridorDepth>> Function(AppConfig) _answer;

  @override
  Future<List<CorridorDepth>> fetchDepth(AppConfig config) => _answer(config);
}

class _EmptyRatesRepository extends RatesRepository {
  _EmptyRatesRepository() : super(Dio());

  @override
  Future<List<CorridorDepth>> fetchDepth(AppConfig config) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(
    RatesRepository repo, {
    bool withConfig = true,
  }) =>
      ProviderContainer(overrides: [
        ratesRepositoryProvider.overrideWithValue(repo),
        translationsProvider.overrideWithValue(translations),
        if (withConfig)
          appConfigProvider.overrideWith(
            () => _ReadyConfig(
              const ConfigState(status: ConfigStatus.ready, config: _config),
            ),
          ),
      ]);

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const MarketDepthScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('queue depth and payout time come from the server', (tester) async {
    final container = containerFor(
      _FakeRatesRepository(
        (config) async => [
          CorridorDepth(
            from: config.currencyByCode('TZS')!,
            to: config.currencyByCode('KES')!,
            queueDepth: 12,
            estimatedSettleSeconds: 900,
            status: const CorridorStatus(
              code: 'balanced_p2p',
              level: CorridorLevel.healthy,
            ),
          ),
        ],
      ),
    );
    await open(tester, container);

    expect(find.text('In queue: 12'), findsOneWidget);
    expect(find.text('Typical payout: 15m'), findsOneWidget);
    expect(find.text('Balanced P2P match'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('no corridors is said plainly', (tester) async {
    final container = containerFor(_EmptyRatesRepository());
    await open(tester, container);

    expect(find.text('No corridors are active right now.'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('no config yet means the screen says it is not connected',
      (tester) async {
    final container = containerFor(_EmptyRatesRepository(), withConfig: false);
    await open(tester, container);

    expect(find.text('Market depth is not connected yet.'), findsOneWidget);

    await finish(tester, container);
  });
}