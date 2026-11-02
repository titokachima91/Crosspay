import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/route_selection_screen.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

Quote _quote({
  DateTime? expiresAt,
  bool bankAvailable = true,
  String? safeguard,
}) =>
    Quote(
      id: 'q1',
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
      rate: 2.0,
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(seconds: 300)),
      routes: [
        RouteQuote(
          route: RouteType.p2p,
          feeBps: 150,
          feeMinor: 15,
          payoutMinor: 50000,
          totalDebitMinor: 1015,
          estimatedMinSeconds: 1800,
          estimatedMaxSeconds: 7200,
          isRecommended: true,
          isAvailable: true,
          status: const CorridorStatus(
            code: 'high_matching_density',
            level: CorridorLevel.healthy,
          ),
          safeguardCode: safeguard,
          breakdown: const [
            FeeLine(code: 'platform_fee', amountMinor: 10),
            FeeLine(code: 'network_fee', amountMinor: 5),
          ],
        ),
        RouteQuote(
          route: RouteType.bank,
          feeBps: 280,
          feeMinor: 28,
          payoutMinor: 50000,
          totalDebitMinor: 1028,
          estimatedMinSeconds: 5,
          estimatedMaxSeconds: 60,
          isRecommended: false,
          isAvailable: bankAvailable,
          status: bankAvailable
              ? const CorridorStatus(
                  code: 'instant_settlement_available',
                  level: CorridorLevel.healthy,
                )
              : null,
          breakdown: const [FeeLine(code: 'platform_fee', amountMinor: 28)],
        ),
      ],
    );

class _FakeTradeRepository extends TradeRepository {
  _FakeTradeRepository(this._answers) : super(Dio());

  final List<Future<Quote> Function()> _answers;
  int calls = 0;

  @override
  Future<Quote> quote({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) {
    final index = calls < _answers.length ? calls : _answers.length - 1;
    calls++;
    return _answers[index]();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(_FakeTradeRepository repo) {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      tradeRepositoryProvider.overrideWithValue(repo),
    ]);
    container.read(quoteProvider.notifier)
      ..setSendCurrency(_a)
      ..setReceiveCurrency(_b)
      ..setSendAmount(1000);
    return container;
  }

  // The countdown keeps scheduling frames, so never pumpAndSettle here.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const RouteSelectionScreen(),
          routes: {
            AppRoutes.recipient: (_) =>
                const Scaffold(body: Text('recipient-screen')),
          },
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('shows both routes with the server figures and preselects the recommended one', (tester) async {
    final repo = _FakeTradeRepository([() async => _quote()]);
    final container = containerFor(repo);
    await open(tester, container);

    expect(repo.calls, 1);
    expect(find.textContaining('Rate locked: 0'), findsOneWidget);
    expect(find.text('Select transfer speed and route'), findsOneWidget);

    expect(find.text('Option A'), findsOneWidget);
    expect(find.text('P2P matching'), findsOneWidget);
    expect(find.text('Best value'), findsOneWidget);
    expect(find.text('Estimated speed: 30 min \u2013 2 h'), findsOneWidget);
    expect(find.text('Platform fee: 1.5% (15 AAA)'), findsOneWidget);
    expect(find.text('Status: High peer matching density'), findsOneWidget);
    expect(find.text('You pay: 1,015 AAA'), findsOneWidget);

    expect(find.text('Option B'), findsOneWidget);
    expect(find.text('Instant bank sweep'), findsOneWidget);
    expect(find.text('Fastest'), findsOneWidget);
    expect(find.text('Estimated speed: under 1 min'), findsOneWidget);
    expect(find.text('Platform fee: 2.8% (28 AAA)'), findsOneWidget);
    expect(find.text('You pay: 1,028 AAA'), findsOneWidget);

    expect(find.text('Recipient gets: 500.00 BBB'), findsNWidgets(2));
    expect(container.read(quoteProvider).selectedRoute, RouteType.p2p);

    await finish(tester, container);
  });

  testWidgets('choosing Option B and proceeding opens the recipient step', (tester) async {
    final container = containerFor(_FakeTradeRepository([() async => _quote()]));
    await open(tester, container);

    await tester.tap(find.text('Instant bank sweep'));
    await tester.pump();
    expect(container.read(quoteProvider).selectedRoute, RouteType.bank);

    await tester.tap(find.text('Proceed with selected route'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('recipient-screen'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('an unavailable route cannot be chosen', (tester) async {
    final container = containerFor(
      _FakeTradeRepository([() async => _quote(bankAvailable: false)]),
    );
    await open(tester, container);

    expect(find.text('Currently unavailable'), findsOneWidget);

    await tester.tap(find.text('Instant bank sweep'));
    await tester.pump();
    expect(container.read(quoteProvider).selectedRoute, RouteType.p2p);

    await finish(tester, container);
  });

  testWidgets('a safeguard claim appears only when the server confirms it', (tester) async {
    final withClaim = containerFor(_FakeTradeRepository([
      () async => _quote(safeguard: 'local_partner_escrow'),
    ]));
    await open(tester, withClaim);
    expect(find.text('Guaranteed by local partner escrow'), findsOneWidget);
    await finish(tester, withClaim);

    final without = containerFor(_FakeTradeRepository([() async => _quote()]));
    await open(tester, without);
    expect(find.text('Guaranteed by local partner escrow'), findsNothing);
    await finish(tester, without);
  });

  testWidgets('the fee breakdown lists exactly the server fee lines', (tester) async {
    final container = containerFor(_FakeTradeRepository([() async => _quote()]));
    await open(tester, container);

    expect(find.text('Mobile network fee'), findsNothing);
    await tester.tap(find.text('FEE BREAKDOWN SUMMARY'));
    await tester.pumpAndSettle();

    expect(find.text('1 BBB = 2.00 AAA'), findsOneWidget);
    expect(find.text('Platform fee'), findsOneWidget);
    expect(find.text('10 AAA'), findsOneWidget);
    expect(find.text('Mobile network fee'), findsOneWidget);
    expect(find.text('5 AAA'), findsOneWidget);
    expect(find.text('Total you pay'), findsOneWidget);
    expect(find.text('1,015 AAA'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('an expired rate offers a new one instead of re-pricing silently', (tester) async {
    final repo = _FakeTradeRepository([
      () async => _quote(
            expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
      () async => _quote(),
    ]);
    final container = containerFor(repo);
    await open(tester, container);

    expect(find.text('Rate expired'), findsOneWidget);
    expect(
      find.text('This rate has expired. Get a new rate to continue.'),
      findsOneWidget,
    );
    expect(find.text('Proceed with selected route'), findsNothing);
    expect(repo.calls, 1);

    await tester.tap(find.text('Get a new rate'));
    await settle(tester);

    expect(repo.calls, 2);
    expect(find.textContaining('Rate locked: 0'), findsOneWidget);
    expect(find.text('Proceed with selected route'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('a failure shows a clear message and can be retried', (tester) async {
    final repo = _FakeTradeRepository([
      () async => throw const ApiException(kind: ApiErrorKind.network),
      () async => _quote(),
    ]);
    final container = containerFor(repo);
    await open(tester, container);

    expect(find.text(translations['en']!.t('error.network')), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await settle(tester);

    expect(find.text('Option A'), findsOneWidget);

    await finish(tester, container);
  });
}
