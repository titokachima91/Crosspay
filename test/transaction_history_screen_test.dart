import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/ledger/screens/transaction_history_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _usd =
    Currency(code: 'USD', name: 'Dollar', countryCode: 'US', decimals: 2);
const _ngn =
    Currency(code: 'NGN', name: 'Naira', countryCode: 'NG', decimals: 2);

Trade _trade({
  required String reference,
  required TradeStatus status,
  required int daysAgo,
  String beneficiary = 'Ada Obi',
}) =>
    Trade(
      id: 'id-$reference',
      reference: reference,
      route: RouteType.p2p,
      status: status,
      sendCurrency: _usd,
      receiveCurrency: _ngn,
      sendAmountMinor: 100000,
      feeMinor: 1500,
      feeBps: 150,
      receiveAmountMinor: 5000000,
      rate: 1500,
      beneficiaryName: beneficiary,
      createdAt: DateTime.now().subtract(Duration(days: daysAgo)),
    );

class _FakeTradeRepository extends TradeRepository {
  _FakeTradeRepository(this._answer) : super(Dio());

  final Future<List<Trade>> Function() _answer;
  int calls = 0;

  @override
  Future<List<Trade>> getTrades(AppConfig config) {
    calls++;
    return _answer();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HistoryRange', () {
    final now = DateTime.utc(2026, 11, 7, 12);

    test('all time keeps every row', () {
      expect(HistoryRange.all.includes(DateTime.utc(2020, 1, 1), now), true);
    });

    test('a window keeps rows inside it and drops the ones outside', () {
      expect(
        HistoryRange.last7.includes(now.subtract(const Duration(days: 6)), now),
        true,
      );
      expect(
        HistoryRange.last7.includes(now.subtract(const Duration(days: 7)), now),
        false,
      );
      expect(
        HistoryRange.last30
            .includes(now.subtract(const Duration(days: 29)), now),
        true,
      );
      expect(
        HistoryRange.last30
            .includes(now.subtract(const Duration(days: 30)), now),
        false,
      );
      expect(
        HistoryRange.last90
            .includes(now.subtract(const Duration(days: 91)), now),
        false,
      );
    });
  });

  ProviderContainer containerFor(_FakeTradeRepository repo) {
    return ProviderContainer(overrides: [
      tradeRepositoryProvider.overrideWithValue(repo),
    ]);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const TransactionHistoryScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  _FakeTradeRepository threeTrades() => _FakeTradeRepository(() async => [
        _trade(
          reference: 'CP-NEW',
          status: TradeStatus.pendingDeposit,
          daysAgo: 1,
          beneficiary: 'Ada Obi',
        ),
        _trade(
          reference: 'CP-MID',
          status: TradeStatus.completed,
          daysAgo: 20,
          beneficiary: 'Bola Ade',
        ),
        _trade(
          reference: 'CP-OLD',
          status: TradeStatus.failed,
          daysAgo: 200,
          beneficiary: 'Chidi Eze',
        ),
      ]);

  testWidgets('every row the server returns is listed by default',
      (tester) async {
    final repo = threeTrades();
    final container = containerFor(repo);
    await open(tester, container);

    expect(repo.calls, 1);
    expect(find.text('CP-NEW · Ada Obi'), findsOneWidget);
    expect(find.text('CP-MID · Bola Ade'), findsOneWidget);
    expect(find.text('CP-OLD · Chidi Eze'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All time'))
          .selected,
      true,
    );

    await finish(tester, container);
  });

  testWidgets('a date window hides the rows outside it', (tester) async {
    final container = containerFor(threeTrades());
    await open(tester, container);

    await tester.tap(find.text('Last 7 days'));
    await tester.pump();

    expect(find.text('CP-NEW · Ada Obi'), findsOneWidget);
    expect(find.text('CP-MID · Bola Ade'), findsNothing);
    expect(find.text('CP-OLD · Chidi Eze'), findsNothing);

    await tester.tap(find.text('All time'));
    await tester.pump();
    expect(find.text('CP-OLD · Chidi Eze'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('the date window and the status chips work together',
      (tester) async {
    final container = containerFor(threeTrades());
    await open(tester, container);

    await tester.tap(find.text('Last 30 days'));
    await tester.pump();
    expect(find.text('CP-MID · Bola Ade'), findsOneWidget);
    expect(find.text('CP-OLD · Chidi Eze'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Done'));
    await tester.pump();
    expect(find.text('CP-MID · Bola Ade'), findsOneWidget);
    expect(find.text('CP-NEW · Ada Obi'), findsNothing);

    await finish(tester, container);
  });

  testWidgets('the search box narrows by reference or recipient',
      (tester) async {
    final container = containerFor(threeTrades());
    await open(tester, container);

    await tester.enterText(find.byType(TextField), 'chidi');
    await tester.pump();
    expect(find.text('CP-OLD · Chidi Eze'), findsOneWidget);
    expect(find.text('CP-NEW · Ada Obi'), findsNothing);

    await tester.enterText(find.byType(TextField), 'CP-MID');
    await tester.pump();
    expect(find.text('CP-MID · Bola Ade'), findsOneWidget);
    expect(find.text('CP-OLD · Chidi Eze'), findsNothing);

    await finish(tester, container);
  });

  testWidgets('an empty window says so instead of showing nothing',
      (tester) async {
    final container = containerFor(_FakeTradeRepository(() async => [
          _trade(
            reference: 'CP-OLD',
            status: TradeStatus.completed,
            daysAgo: 200,
          ),
        ]));
    await open(tester, container);

    await tester.tap(find.text('Last 7 days'));
    await tester.pump();

    expect(find.text('No trades found.'), findsOneWidget);
    expect(find.text('CP-OLD · Ada Obi'), findsNothing);

    await finish(tester, container);
  });

  testWidgets('an unavailable endpoint is said plainly', (tester) async {
    final repo = _FakeTradeRepository(
        () async => throw const ApiException(kind: ApiErrorKind.network));
    final container = containerFor(repo);
    await open(tester, container);

    expect(find.textContaining('not connected'), findsOneWidget);

    await finish(tester, container);
  });
}