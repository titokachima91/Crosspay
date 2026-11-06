import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/beneficiary_input_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/providers/recipient_check_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'YY', decimals: 2);

const _mobile = PayoutRail(
  id: 'r-mobile',
  name: 'Mobile Rail',
  countryCode: 'YY',
  kind: PayoutKind.mobileMoney,
);
const _bank = PayoutRail(
  id: 'r-bank',
  name: 'Bank Rail',
  countryCode: 'YY',
  kind: PayoutKind.bank,
);
const _elsewhere = PayoutRail(
  id: 'r-other',
  name: 'Other Rail',
  countryCode: 'ZZ',
  kind: PayoutKind.mobileMoney,
);

const _config = AppConfig(
  currencies: [_a, _b],
  countries: [
    Country(
      code: 'YY',
      name: 'Destland',
      dialCode: '888',
      nationalNumberLength: 9,
    ),
  ],
  payoutRails: [_mobile, _bank, _elsewhere],
);

Quote _quote({DateTime? expiresAt}) => Quote(
      id: 'q1',
      sendCurrency: _a,
      receiveCurrency: _b,
      sendAmountMinor: 1000,
      rate: 2,
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(seconds: 300)),
      routes: const [
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
        ),
      ],
    );

class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository() : super(Dio());

  @override
  Future<AppConfig> fetch() async => _config;
}

/// An account ending in 0 is not found; a name containing "mismatch" does not
/// match; "unverifiable" cannot be checked; anything else matches.
class _FakeBeneficiaryRepository extends BeneficiaryRepository {
  _FakeBeneficiaryRepository() : super(Dio());

  @override
  Future<RecipientCheck> check({
    required PayoutRail rail,
    required String account,
    String? name,
  }) async {
    if (account.endsWith('0')) {
      return const RecipientCheck(accountStatus: AccountStatus.notFound);
    }
    NameMatch? match;
    if (name != null) {
      final lower = name.toLowerCase();
      match = lower.contains('mismatch')
          ? NameMatch.mismatch
          : lower.contains('unverifiable')
              ? NameMatch.unavailable
              : NameMatch.match;
    }
    return RecipientCheck(
      accountStatus: AccountStatus.found,
      networkName: 'Test Network',
      nameMatch: match,
    );
  }
}

void main() {
  // settled after every typed field
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  Future<ProviderContainer> containerReady({Beneficiary? saved}) async {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      configRepositoryProvider.overrideWithValue(_FakeConfigRepository()),
      beneficiaryRepositoryProvider
          .overrideWithValue(_FakeBeneficiaryRepository()),
      recipientCheckDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    await container.read(appConfigProvider.notifier).load();
    container.read(quoteProvider.notifier)
      ..setSendCurrency(_a)
      ..setReceiveCurrency(_b)
      ..setSendAmount(1000)
      ..quoteReceived(_quote());
    if (saved != null) {
      container.read(tradeProvider.notifier).selectBeneficiary(saved);
    }
    return container;
  }

  // The rate-lock countdown keeps scheduling frames: never pumpAndSettle.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const BeneficiaryInputScreen(),
          routes: {
            AppRoutes.payment: (_) =>
                const Scaffold(body: Text('payment-screen')),
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

  ElevatedButton authorizeButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  Finder field(int index) => find.byType(TextField).at(index);

  testWidgets('lists only the destination payout options and starts disabled', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    expect(find.text('Step 2 of 3'), findsOneWidget);
    expect(find.text('Recipient details'), findsOneWidget);
    expect(find.text('Mobile Rail'), findsOneWidget);
    expect(find.text('Bank Rail'), findsOneWidget);
    expect(find.text('Other Rail'), findsNothing);
    expect(find.textContaining('+888'), findsOneWidget);
    expect(find.text('Authorize payment (1,015 AAA)'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNull);

    await finish(tester, container);
  });

  testWidgets('a confirmed account and a matching name allow authorizing', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.enterText(field(0), '712345678');
    await settle(tester);
    expect(find.text('Network confirmed: Test Network'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNull); // no name yet

    await tester.enterText(field(1), 'Test Person');
    await settle(tester);
    expect(find.text('Name matches the registered account'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNotNull);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('payment-screen'), findsOneWidget);
    final trade = container.read(tradeProvider);
    expect(trade.recipient?.account, '+888712345678');
    expect(trade.recipient?.name, 'Test Person');
    expect(trade.attemptKey, isNotNull);

    await finish(tester, container);
  });

  testWidgets('a mismatching name blocks authorizing with a clear message', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.enterText(field(0), '712345678');
    await settle(tester);
    await tester.enterText(field(1), 'Test mismatch');
    await settle(tester);

    expect(
      find.text(
        'The name does not match this account. Please check the name and number.',
      ),
      findsOneWidget,
    );
    expect(authorizeButton(tester).onPressed, isNull);

    await finish(tester, container);
  });

  testWidgets('an unknown account blocks authorizing', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.enterText(field(0), '712345670');
    await settle(tester);
    await tester.enterText(field(1), 'Test Person');
    await settle(tester);

    expect(
      find.text('We could not find this account. Please check the number.'),
      findsOneWidget,
    );
    expect(authorizeButton(tester).onPressed, isNull);

    await finish(tester, container);
  });

  testWidgets('a name that cannot be checked is allowed with a warning', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.enterText(field(0), '712345678');
    await settle(tester);
    await tester.enterText(field(1), 'Test unverifiable');
    await settle(tester);

    expect(
      find.text(
        'The name could not be verified automatically. Please check the '
        'details carefully before you pay.',
      ),
      findsOneWidget,
    );
    expect(authorizeButton(tester).onPressed, isNotNull);

    await finish(tester, container);
  });

  testWidgets('a bank payout asks for an account number without a calling code', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.tap(find.text('Bank Rail'));
    await settle(tester);

    expect(find.text('Recipient account number'), findsOneWidget);
    expect(find.textContaining('+888'), findsNothing);

    await tester.enterText(field(0), '12345678');
    await settle(tester);
    await tester.enterText(field(1), 'Test Person');
    await settle(tester);

    expect(find.text('Network confirmed: Test Network'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNotNull);

    await finish(tester, container);
  });

  testWidgets('a saved recipient prefills the form and is checked again', (tester) async {
    final container = await containerReady(
      saved: const Beneficiary(
        id: 'b1',
        name: 'Saved Person',
        rail: _mobile,
        accountOrPhone: '+888712345678',
        kycVerified: true,
      ),
    );
    await open(tester, container);

    expect(find.text('712 345 678'), findsOneWidget);
    expect(find.text('Saved Person'), findsOneWidget);
    expect(find.text('Name matches the registered account'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNotNull);

    await finish(tester, container);
  });

  testWidgets('when the rate lock ends, authorizing is blocked and the way back is offered', (tester) async {
    final container = await containerReady();
    await open(tester, container);

    await tester.enterText(field(0), '712345678');
    await settle(tester);
    await tester.enterText(field(1), 'Test Person');
    await settle(tester);
    expect(authorizeButton(tester).onPressed, isNotNull);

    container.read(quoteProvider.notifier).quoteReceived(
          _quote(expiresAt: DateTime.now().subtract(const Duration(seconds: 1))),
        );
    await settle(tester);

    expect(
      find.text('The locked rate has ended. Go back to get a new rate.'),
      findsOneWidget,
    );
    expect(find.text('Back'), findsOneWidget);
    expect(authorizeButton(tester).onPressed, isNull);

    await finish(tester, container);
  });
}
