import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/widgets/trade_timeline_card.dart';
import 'package:crosspay_app/models/trade_event_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
class _FakeTimelineRepository extends TradeRepository {
  _FakeTimelineRepository(this._answer) : super(Dio());

  final Future<List<TradeEvent>> Function() _answer;
  int calls = 0;

  @override
  Future<List<TradeEvent>> fetchTimeline(String tradeId) {
    calls++;
    return _answer();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(_FakeTimelineRepository repo) =>
      ProviderContainer(overrides: [
        tradeRepositoryProvider.overrideWithValue(repo),
        translationsProvider.overrideWithValue(translations),
      ]);

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: TradeTimelineCard(tradeId: 'trade-1'),
            ),
          ),
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

  group('trade status naming', () {
    test('every status carries the server code and a label key', () {
      expect(TradeStatus.pendingDeposit.code, 'pending_deposit');
      expect(TradeStatus.completed.code, 'completed');
      expect(TradeStatus.completed.labelKey, 'trade.status.completed');
      expect(TradeStatus.cancelled.labelKey, 'trade.status.cancelled');
    });

    test('both dictionaries translate every status label', () {
      for (final code in AppLocalizations.supportedCodes) {
        for (final status in TradeStatus.values) {
          expect(
            translations[code]!.has(status.labelKey),
            true,
            reason: '$code is missing ${status.labelKey}',
          );
        }
      }
    });
  });

  testWidgets('the events the server sent are listed in order', (tester) async {
    final now = DateTime.utc(2026, 11, 7, 12);
    final repo = _FakeTimelineRepository(() async => [
          TradeEvent(
            status: TradeStatus.pendingDeposit,
            at: now.subtract(const Duration(minutes: 40)),
          ),
          TradeEvent(
            status: TradeStatus.escrowed,
            at: now.subtract(const Duration(minutes: 30)),
            noteCode: 'payment_seen',
          ),
          TradeEvent(status: TradeStatus.matching, at: now),
        ]);
    final container = containerFor(repo);
    await open(tester, container);

    expect(repo.calls, 1);
    expect(find.text('Status timeline'), findsNothing);
    expect(find.text('STATUS TIMELINE'), findsOneWidget);
    expect(find.text('Waiting for payment'), findsOneWidget);
    expect(find.text('Verifying payment'), findsOneWidget);
    expect(find.text('Finding payout route'), findsOneWidget);
    expect(find.text('Timeline is not connected yet.'), findsNothing);

    await finish(tester, container);
  });

  testWidgets('an empty timeline is said plainly', (tester) async {
    final container = containerFor(_FakeTimelineRepository(() async => []));
    await open(tester, container);

    expect(find.text('No status changes recorded yet.'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('an endpoint that is not configured says so', (tester) async {
    final container = containerFor(
      _FakeTimelineRepository(
        () async => throw const ApiException(kind: ApiErrorKind.notConfigured),
      ),
    );
    await open(tester, container);

    expect(find.text('Timeline is not connected yet.'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('a network failure shows the failure message', (tester) async {
    final container = containerFor(
      _FakeTimelineRepository(
        () async => throw const ApiException(kind: ApiErrorKind.network),
      ),
    );
    await open(tester, container);

    expect(
      find.text('No connection. Please check your internet and try again.'),
      findsOneWidget,
    );

    await finish(tester, container);
  });
}