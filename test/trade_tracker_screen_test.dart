import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/support/screens/support_screen.dart';
import 'package:crosspay_app/features/transaction/screens/trade_tracker_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/trade_event_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

import 'support/payment_fakes.dart';

class _TrackerRepository extends FakeTradeRepository {
  _TrackerRepository()
      : super(onFetch: () async => fakeTrade(TradeStatus.escrowed));

  @override
  Future<List<TradeEvent>> fetchTimeline(String tradeId) async => const [];
}

class _EmptyConfigRepository extends ConfigRepository {
  _EmptyConfigRepository() : super(Dio());

  @override
  Future<AppConfig> fetch() async => const AppConfig();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(TradeStatus status, {String? hash}) {
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        tradeRepositoryProvider.overrideWithValue(_TrackerRepository()),
        configRepositoryProvider.overrideWithValue(_EmptyConfigRepository()),
      ],
    );
    container
        .read(tradeProvider.notifier)
        .tradeStarted(fakeTrade(status).copyWith(verificationHash: hash));
    return container;
  }

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const TradeTrackerScreen(),
          routes: {
            AppRoutes.support: (_) => const SupportScreen(),
            AppRoutes.invoice: (_) =>
                const Scaffold(body: Text('invoice-screen')),
            AppRoutes.home: (_) => const Scaffold(body: Text('home-screen')),
          },
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

  testWidgets('a short screen scrolls and never overflows', (tester) async {
    final container = containerFor(TradeStatus.escrowed, hash: 'hash-123');
    await open(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.text('Verifying payment'), findsWidgets);
    expect(find.text('Contact support'), findsOneWidget);
    expect(find.text('Share invoice'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Verification Hash'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('Contact support opens the support screen with the trade',
      (tester) async {
    final container = containerFor(TradeStatus.escrowed, hash: 'hash-123');
    await open(tester, container);

    await tester.tap(find.text('Contact support'));
    await tester.pumpAndSettle();

    expect(find.text('Help & support'), findsOneWidget);
    expect(find.text('REF-1'), findsOneWidget);
    expect(find.text('TRADE DETAILS'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('a finished trade shows Done instead of the live actions',
      (tester) async {
    final container = containerFor(TradeStatus.completed);
    await open(tester, container);

    expect(find.widgetWithText(CustomButton, 'Done'), findsOneWidget);
    expect(find.text('Contact support'), findsNothing);
    expect(find.text('Share invoice'), findsNothing);
    expect(tester.takeException(), isNull);

    await finish(tester, container);
  });
}
