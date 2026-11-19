import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/invoice_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

import 'support/payment_fakes.dart';

class _InvoiceRepository extends FakeTradeRepository {
  _InvoiceRepository({required this.onInvoice})
      : super(onFetch: () async => fakeTrade(TradeStatus.pendingDeposit));

  final Future<Invoice> Function() onInvoice;
  int invoiceCalls = 0;

  @override
  Future<Trade> getTrade(String tradeId, AppConfig config) async =>
      fakeTrade(TradeStatus.pendingDeposit);

  @override
  Future<Invoice> getInvoice(String tradeId, {required AppConfig config}) {
    invoiceCalls++;
    return onInvoice();
  }
}

class _EmptyConfigRepository extends ConfigRepository {
  _EmptyConfigRepository() : super(Dio());

  @override
  Future<AppConfig> fetch() async => const AppConfig();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;
  late List<MethodCall> platformCalls;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  ProviderContainer containerFor(_InvoiceRepository repository) {
    return ProviderContainer(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        tradeRepositoryProvider.overrideWithValue(repository),
        configRepositoryProvider.overrideWithValue(_EmptyConfigRepository()),
      ],
    );
  }

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          onGenerateInitialRoutes: (_) => [
            MaterialPageRoute<void>(
              settings: const RouteSettings(
                name: AppRoutes.invoice,
                arguments: {'tradeId': 't1'},
              ),
              builder: (_) => const InvoiceScreen(),
            ),
          ],
          routes: {
            AppRoutes.home: (_) => const Scaffold(body: Text('home-screen')),
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('shows the server amount, reference and issued link',
      (tester) async {
    final repository = _InvoiceRepository(
      onInvoice: () async => Invoice(
        tradeId: 't1',
        qrCodeUrl: 'https://api.test/invoices/token/qr.png',
        shareUrl: 'https://pay.test/pay/token',
        validUntil: DateTime.now().add(const Duration(hours: 72)),
        amountMinor: 1015,
        currency: 'AAA',
      ),
    );
    final container = containerFor(repository);
    await open(tester, container);

    expect(find.text('Invoice #REF-1'), findsOneWidget);
    expect(find.text('1,015 AAA'), findsOneWidget);
    expect(find.text('Scan to pay'), findsOneWidget);
    expect(find.text('Copy invoice link'), findsOneWidget);
    expect(repository.invoiceCalls, 1);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Copy invoice link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy invoice link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Invoice link copied'), findsOneWidget);
    final copied = platformCalls.last;
    expect(copied.method, 'Clipboard.setData');
    expect((copied.arguments as Map<dynamic, dynamic>)['text'],
        'https://pay.test/pay/token');

    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('shows an honest error when links are not configured',
      (tester) async {
    final repository = _InvoiceRepository(
      onInvoice: () async => throw const ApiException(
        kind: ApiErrorKind.server,
        statusCode: 503,
        code: 'INVOICE_NOT_CONFIGURED',
      ),
    );
    final container = containerFor(repository);
    await open(tester, container);

    expect(
      find.text('Invoice links are not configured on this server.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Copy invoice link'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}
