import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/transaction/screens/home_dashboard_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';
import 'package:crosspay_app/repositories/rates_repository.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

// Test stand-ins and inputs only. Not app code or app data.
const _a = Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 0);
const _b = Currency(code: 'BBB', name: 'Beta', countryCode: 'ZZ', decimals: 2);

const _config = AppConfig(
  currencies: [_a, _b],
  countries: [
    Country(
      code: 'ZZ',
      name: 'Testland',
      dialCode: '999',
      nationalNumberLength: 9,
    ),
  ],
  payoutRails: [PayoutRail(id: 'r1', name: 'Rail One', countryCode: 'ZZ', kind: PayoutKind.mobileMoney)],
);

class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository(this._outcome) : super(Dio());

  final Future<AppConfig> Function() _outcome;

  @override
  Future<AppConfig> fetch() => _outcome();
}

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository(this._profile) : super(Dio());

  final UserProfile _profile;

  @override
  Future<UserProfile> fetch(AppConfig config) async => _profile;
}

class _FakeBeneficiaryRepository extends BeneficiaryRepository {
  _FakeBeneficiaryRepository() : super(Dio());

  @override
  Future<List<Beneficiary>> list(AppConfig config) async => [
        Beneficiary(
          id: 'b1',
          name: 'Test Recipient',
          rail: config.payoutRails.first,
          accountOrPhone: '+999700000001',
          kycVerified: true,
        ),
      ];
}

class _FakeRatesRepository extends RatesRepository {
  _FakeRatesRepository() : super(Dio());

  @override
  Future<RatesSnapshot> fetch(AppConfig config) async => const RatesSnapshot(
        rates: [
          CorridorRate(
            from: _a,
            to: _b,
            rate: 2.0,
            status: CorridorStatus(
              code: 'balanced_p2p',
              level: CorridorLevel.healthy,
            ),
          ),
        ],
      );
}

/// 1,000 AAA (no decimals) becomes 500.00 BBB (two decimals) = 50000 units.
class _FakeTradeRepository extends TradeRepository {
  _FakeTradeRepository() : super(Dio());

  @override
  Future<Estimate> estimate({
    required Currency sendCurrency,
    required Currency receiveCurrency,
    required int sendAmountMinor,
  }) async =>
      Estimate(
        rate: 2.0,
        receiveAmountMinor: sendAmountMinor * 50,
        estimatedMinSeconds: 1800,
        estimatedMaxSeconds: 7200,
        route: RouteType.p2p,
      );
}

UserProfile _profile({KycStatus kyc = KycStatus.verified}) => UserProfile(
      id: 'u1',
      phone: '+999712345678',
      displayName: 'Test Person',
      accountType: AccountType.personal,
      kycStatus: kyc,
      limitCurrency: _a,
      dailyLimitMinor: 10000,
      dailyUsedMinor: 2000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerWith({
    UserProfile? profile,
    Future<AppConfig> Function()? config,
  }) {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      estimateDebounceProvider.overrideWithValue(Duration.zero),
      configRepositoryProvider.overrideWithValue(
        _FakeConfigRepository(config ?? () async => _config),
      ),
      profileRepositoryProvider
          .overrideWithValue(_FakeProfileRepository(profile ?? _profile())),
      beneficiaryRepositoryProvider
          .overrideWithValue(_FakeBeneficiaryRepository()),
      ratesRepositoryProvider.overrideWithValue(_FakeRatesRepository()),
      tradeRepositoryProvider.overrideWithValue(_FakeTradeRepository()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> show(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          initialRoute: AppRoutes.home,
          routes: {
            AppRoutes.home: (_) => const Scaffold(body: HomeDashboardScreen()),
            AppRoutes.review: (_) =>
                const Scaffold(body: Text('review-screen')),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ElevatedButton reviewButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  testWidgets('a verified person can type an amount and review the route', (tester) async {
    final container = containerWith();
    await show(tester, container);

    expect(find.text('Test Person'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Available today: 8,000 AAA'), findsOneWidget);
    expect(find.textContaining('Regional clearing active'), findsOneWidget);
    expect(find.text('Test Recipient'), findsOneWidget);
    expect(reviewButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '1000');
    await tester.pumpAndSettle();

    expect(find.text('500.00'), findsOneWidget);
    expect(
      find.text('Estimated delivery: ~30 min (P2P corridor)'),
      findsOneWidget,
    );
    expect(find.text('Review and select route (1,000 AAA)'), findsOneWidget);
    expect(reviewButton(tester).onPressed, isNotNull);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(find.text('review-screen'), findsOneWidget);
  });

  testWidgets('a pending person sees the pending message and cannot review', (tester) async {
    final container = containerWith(profile: _profile(kyc: KycStatus.pending));
    await show(tester, container);

    await tester.enterText(find.byType(TextField), '1000');
    await tester.pumpAndSettle();

    expect(find.text('Pending'), findsOneWidget);
    expect(
      find.text(
        'Your verification is still being checked. You can look around, '
        'but you cannot send money yet.',
      ),
      findsOneWidget,
    );
    expect(reviewButton(tester).onPressed, isNull);
  });

  testWidgets('more than the available limit is blocked with a clear message', (tester) async {
    final container = containerWith();
    await show(tester, container);

    await tester.enterText(find.byType(TextField), '9000');
    await tester.pumpAndSettle();

    expect(
      find.text(
        'That is more than you can send today. Available today: 8,000 AAA.',
      ),
      findsOneWidget,
    );
    expect(reviewButton(tester).onPressed, isNull);
  });

  testWidgets('tapping a saved recipient selects it', (tester) async {
    final container = containerWith();
    await show(tester, container);

    await tester.tap(find.text('Test Recipient'));
    await tester.pump();

    expect(container.read(tradeProvider).beneficiary?.id, 'b1');
  });

  testWidgets('says plainly when the server data cannot be loaded', (tester) async {
    final container = containerWith(
      config: () async => throw const ApiException(kind: ApiErrorKind.network),
    );
    await show(tester, container);

    expect(find.text(translations['en']!.t('error.network')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
