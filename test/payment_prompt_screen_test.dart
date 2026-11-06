import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/payment_prompt_screen.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/payment_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

import 'support/payment_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(FakeTradeRepository repo) {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      tradeRepositoryProvider.overrideWithValue(repo),
      // The server's seconds become 10 ms each: 30 s -> 300 ms, 2 s -> 20 ms.
      paymentDurationProvider
          .overrideWithValue((seconds) => Duration(milliseconds: seconds * 10)),
      attemptKeyGeneratorProvider.overrideWithValue(() => 'key-1'),
    ]);
    container.read(quoteProvider.notifier).quoteReceived(fakeQuote());
    container
        .read(tradeProvider.notifier)
        .authorize(fakeRecipient(), quoteId: 'q1');
    return container;
  }

  // Timers keep scheduling frames: never pumpAndSettle here.
  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          initialRoute: AppRoutes.payment,
          routes: {
            AppRoutes.payment: (_) => const PaymentPromptScreen(),
            AppRoutes.tracker: (_) =>
                const Scaffold(body: Text('tracker-screen')),
            AppRoutes.home: (_) => const Scaffold(body: Text('home-screen')),
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  Future<void> goHome(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('tells the person to approve on their phone and waits', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = containerFor(repo);
    await open(tester, container);

    expect(find.text('Payment request sent to your phone'), findsOneWidget);
    expect(
      find.text(
        'Check your phone screen. Enter your Test Network PIN to approve '
        'paying 1,015 AAA.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Waiting for confirmation from your mobile money provider...'),
      findsOneWidget,
    );
    expect(find.text('FALLBACK: MANUAL PAYMENT'), findsOneWidget);
    expect(
      find.text('If the prompt did not appear on your phone, pay manually:'),
      findsNothing,
    );

    await finish(tester, container);
  });

  testWidgets('the manual details open after the timeout and can be confirmed', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = containerFor(repo);
    await open(tester, container);

    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('If the prompt did not appear on your phone, pay manually:'),
      findsOneWidget,
    );
    expect(find.text('Business / Paybill number'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('Account / reference code'), findsOneWidget);
    expect(find.text('REF-1'), findsOneWidget);
    expect(find.text('1,015 AAA'), findsOneWidget);

    await tester.tap(find.text('I have completed manual payment'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));

    expect(repo.claimCalls, 1);
    expect(find.text('Checking for your manual payment...'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('the person can open the manual details early', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = containerFor(repo);
    await open(tester, container);

    await tester.tap(find.text('FALLBACK: MANUAL PAYMENT'));
    await tester.pump();

    expect(find.text('123456'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('without a prompt the manual details are shown at once', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(pushSent: false),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = containerFor(repo);
    await open(tester, container);

    expect(
      find.text(
        'We could not send a prompt to your phone. Please pay manually using '
        'the details below.',
      ),
      findsOneWidget,
    );
    expect(find.text('123456'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('when the deposit arrives the person is taken to the tracker', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.escrowed),
    );
    final container = containerFor(repo);
    await open(tester, container);

    await tester.pump(const Duration(milliseconds: 50));
    await goHome(tester);

    expect(find.text('tracker-screen'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('cancelling asks first, then returns Home', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
      onCancel: () async => fakeTrade(TradeStatus.cancelled),
    );
    final container = containerFor(repo);
    await open(tester, container);

    await tester.tap(find.text('Cancel transaction'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Cancel this transaction?'), findsOneWidget);

    // Keeping the payment going closes the dialog and cancels nothing.
    await tester.tap(find.text('Keep waiting'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Cancel this transaction?'), findsNothing);
    expect(repo.cancelCalls, 0);

    await tester.tap(find.text('Cancel transaction'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cancel transaction'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await goHome(tester);

    expect(repo.cancelCalls, 1);
    expect(find.text('home-screen'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('a failed start shows a clear message and can be retried', (tester) async {
    var attempts = 0;
    final repo = FakeTradeRepository(
      onInitiate: () async {
        attempts++;
        if (attempts == 1) {
          throw const ApiException(
            kind: ApiErrorKind.client,
            statusCode: 422,
            code: 'QUOTE_EXPIRED',
          );
        }
        return fakeInitiated();
      },
      onFetch: () async => fakeTrade(TradeStatus.pendingDeposit),
    );
    final container = containerFor(repo);
    await open(tester, container);

    expect(
      find.text(translations['en']!.t('error.code.quote_expired')),
      findsOneWidget,
    );

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));

    expect(find.text('Payment request sent to your phone'), findsOneWidget);
    expect(repo.initiateCalls, 2);
    expect(repo.lastKey, 'key-1');

    await finish(tester, container);
  });

  testWidgets('a payment that did not complete says so with its reference', (tester) async {
    final repo = FakeTradeRepository(
      onInitiate: () async => fakeInitiated(),
      onFetch: () async => fakeTrade(TradeStatus.expired),
    );
    final container = containerFor(repo);
    await open(tester, container);

    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text(
        'This payment was not completed. If you were charged, contact support '
        'and quote reference REF-1.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Back to Home'));
    await goHome(tester);
    expect(find.text('home-screen'), findsOneWidget);

    await finish(tester, container);
  });
}
