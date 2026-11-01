import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/onboarding/screens/kyc_profile_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

// Test stand-ins and inputs only. Not app code or app data.
const _testConfig = AppConfig(
  currencies: [Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 2)],
  hubs: [
    TradingHub(id: 'h1', name: 'Hub One', countryCode: 'ZZ'),
    TradingHub(id: 'h2', name: 'Hub Two', countryCode: 'ZZ'),
  ],
  countries: [
    Country(
      code: 'ZZ',
      name: 'Testland',
      dialCode: '999',
      nationalNumberLength: 9,
    ),
  ],
);

typedef _Submit = Future<KycStatus> Function(
  AccountType type,
  String legalName,
  String? hubId,
  String idNumber,
);

class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository(this._outcome) : super(Dio());

  final Future<AppConfig> Function() _outcome;

  @override
  Future<AppConfig> fetch() => _outcome();
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository(this._onSubmit) : super(Dio());

  final _Submit _onSubmit;

  @override
  Future<OtpChallenge> requestOtp(String phone) async => OtpChallenge(
        codeLength: 4,
        resendAfterSeconds: 30,
        expiresInSeconds: 300,
        requestedAt: DateTime.now(),
      );

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async =>
      const AuthSession(accessToken: 'test-token', profileComplete: false);

  @override
  Future<KycStatus> submitKyc({
    required AccountType accountType,
    required String legalName,
    String? hubId,
    required String idNumber,
  }) =>
      _onSubmit(accountType, legalName, hubId, idNumber);
}

class _MemoryTokenStorage implements TokenStorage {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> delete() async => token = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  Future<ProviderContainer> signedInContainer({
    required _Submit onSubmit,
    Future<AppConfig> Function()? config,
  }) async {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      configRepositoryProvider.overrideWithValue(
        _FakeConfigRepository(config ?? () async => _testConfig),
      ),
      authRepositoryProvider.overrideWithValue(_FakeAuthRepository(onSubmit)),
      tokenStorageProvider.overrideWithValue(_MemoryTokenStorage()),
    ]);
    addTearDown(container.dispose);

    await container.read(appConfigProvider.notifier).load();
    await container.read(authProvider.notifier).requestOtp('+999712345678');
    await container.read(authProvider.notifier).verifyOtp('1234');
    return container;
  }

  Widget appFor(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        initialRoute: AppRoutes.kyc,
        routes: {
          AppRoutes.kyc: (_) => const KycProfileScreen(),
          AppRoutes.home: (_) => const Scaffold(body: Text('home-screen')),
          AppRoutes.splash: (_) => const Scaffold(body: Text('splash-screen')),
        },
      ),
    );
  }

  ElevatedButton submitButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  Future<void> fillNameAndId(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), '  Test Person  ');
    await tester.enterText(find.byType(TextField).at(1), ' TEST-ID-1 ');
    await tester.pumpAndSettle();
  }

  Future<void> chooseHub(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<TradingHub>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> switchToBusiness(WidgetTester tester) async {
    await tester.tap(find.text('Business'));
    await tester.pumpAndSettle();
  }

  testWidgets('a person is the default: no market field, submit needs name and ID', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => KycStatus.verified,
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Verify your identity'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<TradingHub>), findsNothing);
    expect(
      find.text('We use this only to verify your business with regulated partners.'),
      findsOneWidget,
    );
    expect(submitButton(tester).onPressed, isNull);

    await fillNameAndId(tester);
    expect(submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('a person sends trimmed values and no market, then opens Home', (tester) async {
    AccountType? sentType;
    String? sentName;
    String? sentHub = 'unset';
    String? sentId;
    final container = await signedInContainer(
      onSubmit: (type, name, hub, id) async {
        sentType = type;
        sentName = name;
        sentHub = hub;
        sentId = id;
        return KycStatus.verified;
      },
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await fillNameAndId(tester);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(sentType, AccountType.personal);
    expect(sentName, 'Test Person');
    expect(sentHub, isNull);
    expect(sentId, 'TEST-ID-1');
    expect(find.text('home-screen'), findsOneWidget);
    expect(container.read(authProvider).kycStatus, KycStatus.verified);
  });

  testWidgets('a business must also choose a market from the server list', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => KycStatus.verified,
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await switchToBusiness(tester);

    expect(find.text('Business registration and KYC'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<TradingHub>), findsOneWidget);

    await fillNameAndId(tester);
    expect(submitButton(tester).onPressed, isNull);

    await chooseHub(tester, 'Hub Two (Testland)');
    expect(submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('a business sends its chosen market', (tester) async {
    AccountType? sentType;
    String? sentHub;
    final container = await signedInContainer(
      onSubmit: (type, name, hub, id) async {
        sentType = type;
        sentHub = hub;
        return KycStatus.verified;
      },
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await switchToBusiness(tester);
    await fillNameAndId(tester);
    await chooseHub(tester, 'Hub Two (Testland)');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(sentType, AccountType.business);
    expect(sentHub, 'h2');
    expect(find.text('home-screen'), findsOneWidget);
  });

  testWidgets('a pending check still opens Home', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => KycStatus.pending,
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await fillNameAndId(tester);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.text('home-screen'), findsOneWidget);
    expect(container.read(authProvider).kycStatus, KycStatus.pending);
  });

  testWidgets('a rejected ID shows a clear message and stays on the form', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => throw const ApiException(
        kind: ApiErrorKind.client,
        statusCode: 422,
        code: 'ID_NUMBER_INVALID',
      ),
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await fillNameAndId(tester);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(
      find.text('That ID or TIN number is not valid. Please check and try again.'),
      findsOneWidget,
    );
    expect(find.text('home-screen'), findsNothing);
  });

  testWidgets('a person can still register when the market list cannot load', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => KycStatus.verified,
      config: () async => throw const ApiException(kind: ApiErrorKind.network),
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    // The personal form needs nothing from the server config.
    expect(find.byType(TextField), findsNWidgets(2));

    await switchToBusiness(tester);

    expect(find.text(translations['en']!.t('error.network')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('returns to the start when the session ends', (tester) async {
    final container = await signedInContainer(
      onSubmit: (_, __, ___, ____) async => KycStatus.verified,
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    await container.read(authProvider.notifier).signOut();
    await tester.pumpAndSettle();

    expect(find.text('splash-screen'), findsOneWidget);
  });
}
