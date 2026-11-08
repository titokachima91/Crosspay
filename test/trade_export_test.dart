import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/ledger/screens/transaction_history_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_export_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
class _FakeExportRepository extends TradeRepository {
  _FakeExportRepository(this._answer) : super(Dio());

  final Future<ExportTicket> Function() _answer;
  int calls = 0;

  @override
  Future<ExportTicket> requestExport() {
    calls++;
    return _answer();
  }

  @override
  Future<List<Trade>> getTrades(AppConfig config) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(_FakeExportRepository repo) =>
      ProviderContainer(overrides: [
        tradeRepositoryProvider.overrideWithValue(repo),
        translationsProvider.overrideWithValue(translations),
      ]);

  ExportTicket ticket() => ExportTicket(
        downloadUrl: 'https://files.example/cp-export.csv',
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      );

  test('a link from the server is kept in the state', () async {
    final container = containerFor(_FakeExportRepository(() async => ticket()));
    addTearDown(container.dispose);

    final answer = await container.read(tradeExportProvider.notifier).request();

    expect(answer, isNotNull);
    expect(answer!.downloadUrl, 'https://files.example/cp-export.csv');
    expect(container.read(tradeExportProvider).ticket, isNotNull);
    expect(container.read(tradeExportProvider).busy, false);
  });

  test('a refusal leaves no link and keeps the message key', () async {
    final container = containerFor(
      _FakeExportRepository(
        () async => throw const ApiException(kind: ApiErrorKind.client),
      ),
    );
    addTearDown(container.dispose);

    final answer = await container.read(tradeExportProvider.notifier).request();

    expect(answer, isNull);
    expect(container.read(tradeExportProvider).ticket, isNull);
    expect(container.read(tradeExportProvider).errorKey, 'error.client');
  });

  testWidgets('the history screen hands over the export link', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repo = _FakeExportRepository(() async => ticket());
    final container = containerFor(repo);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const TransactionHistoryScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    await tester.pump();

    expect(repo.calls, 1);
    expect(find.text('Your export link is ready.'), findsOneWidget);
    expect(find.text('https://files.example/cp-export.csv'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}