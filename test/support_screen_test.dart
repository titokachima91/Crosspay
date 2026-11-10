import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/support/models/support_trade_context.dart';
import 'package:crosspay_app/features/support/screens/support_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

class _SupportConfigRepository extends ConfigRepository {
  _SupportConfigRepository(this._config) : super(Dio());

  final AppConfig _config;

  @override
  Future<AppConfig> fetch() async => _config;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  ProviderContainer containerFor({required AppConfig config}) =>
      ProviderContainer(
        overrides: [
          translationsProvider.overrideWithValue(translations),
          configRepositoryProvider
              .overrideWithValue(_SupportConfigRepository(config)),
        ],
      );

  Future<void> openSupport(
    WidgetTester tester,
    ProviderContainer container, {
    SupportTradeContext? trade,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          navigatorKey: navigator,
          home: const Scaffold(body: Text('home-screen')),
          routes: {
            AppRoutes.support: (_) => const SupportScreen(),
          },
        ),
      ),
    );

    navigator.currentState!.pushNamed(
      AppRoutes.support,
      arguments: trade,
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('without server channels it says so plainly', (tester) async {
    final container = containerFor(config: const AppConfig());
    await openSupport(
      tester,
      container,
      trade: const SupportTradeContext(
        tradeId: 't1',
        reference: 'REF-1',
        status: TradeStatus.escrowed,
        verificationHash: 'hash-123',
      ),
    );

    expect(find.text('Help & support'), findsOneWidget);
    expect(find.text('TRADE DETAILS'), findsOneWidget);
    expect(find.text('REF-1'), findsOneWidget);
    expect(find.text('Verifying payment'), findsOneWidget);
    expect(
      find.text('Support contact options are not available yet'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.textContaining('Sending from the app is not connected yet'),
      200,
    );
    await tester.pump();

    expect(
      find.textContaining('Sending from the app is not connected yet'),
      findsOneWidget,
    );

    await finish(tester, container);
  });

  testWidgets('server channels are listed and can be copied', (tester) async {
    final container = containerFor(
      config: const AppConfig(
        support: SupportInfo(
          email: 'help@example.test',
          phone: '+999700000',
          whatsapp: '+999700001',
          hours: 'Mon-Fri 08:00-18:00',
        ),
      ),
    );
    await openSupport(tester, container);

    expect(find.text('help@example.test'), findsOneWidget);
    expect(find.text('+999700000'), findsOneWidget);
    expect(find.text('+999700001'), findsOneWidget);
    expect(find.text('Hours: Mon-Fri 08:00-18:00'), findsOneWidget);
    expect(
      find.text('Support contact options are not available yet'),
      findsNothing,
    );

    await tester.tap(find.text('help@example.test'));
    await tester.pumpAndSettle();
    expect(find.text('Copied to clipboard'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('without a trade it explains how to attach one', (tester) async {
    final container = containerFor(config: const AppConfig());
    await openSupport(tester, container);

    expect(
      find.text(
          'Open this screen from a trade to attach its details automatically.'),
      findsOneWidget,
    );
    expect(find.text('TRADE DETAILS'), findsNothing);

    await finish(tester, container);
  });
}
