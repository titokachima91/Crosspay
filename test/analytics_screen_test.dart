import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/ledger/screens/analytics_screen.dart';
import 'package:crosspay_app/models/analytics_model.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

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

class _FakeAnalyticsRepository extends TradeRepository {
  _FakeAnalyticsRepository(this._answer) : super(Dio());

  final Future<TradeAnalytics> Function(AppConfig) _answer;

  @override
  Future<TradeAnalytics> fetchAnalytics(AppConfig config) => _answer(config);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(_FakeAnalyticsRepository repo, {bool withConfig = true}) =>
      ProviderContainer(overrides: [
        tradeRepositoryProvider.overrideWithValue(repo),
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
        child: MaterialApp(theme: AppTheme.light, home: const AnalyticsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('the totals and corridor split the server sent are shown',
      (tester) async {
    final container = containerFor(
      _FakeAnalyticsRepository(
        (config) async => TradeAnalytics(
          trades: 3,
          sentMinor: 3600000,
          sentCurrency: config.currencyByCode('TZS')!,
          receivedMinor: 72900,
          receivedCurrency: config.currencyByCode('KES')!,
          corridors: [
            CorridorSpend(
              from: config.currencyByCode('TZS')!,
              to: config.currencyByCode('KES')!,
              trades: 3,
              sentMinor: 3600000,
            ),
          ],
        ),
      ),
    );
    await open(tester, container);

    expect(find.text('Spending'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Total sent'), findsOneWidget);
    expect(find.text('TZS 3,600,000'), findsWidgets);
    expect(find.text('KES 729.00'), findsOneWidget);
    expect(find.text('TZS → KES'), findsOneWidget);
    expect(find.text('BY CORRIDOR'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('no config yet means the screen says it is not connected',
      (tester) async {
    final container = containerFor(
      _FakeAnalyticsRepository(
        (config) async => throw const ApiException(kind: ApiErrorKind.network),
      ),
      withConfig: false,
    );
    await open(tester, container);

    expect(
      find.text('Spending analytics are not connected yet.'),
      findsOneWidget,
    );

    await finish(tester, container);
  });
}