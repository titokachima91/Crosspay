import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/onboarding/screens/phone_entry_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

// Test stand-ins and inputs only. Not app code or app data.
class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository(this._outcome) : super(Dio());

  final Future<AppConfig> Function() _outcome;

  @override
  Future<AppConfig> fetch() => _outcome();
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(Dio());

  String? sentTo;

  @override
  Future<OtpChallenge> requestOtp(String phone) async {
    sentTo = phone;
    return OtpChallenge(
      codeLength: 4,
      resendAfterSeconds: 30,
      expiresInSeconds: 300,
      requestedAt: DateTime.now(),
    );
  }
}

const _testConfig = AppConfig(
  currencies: [Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ')],
  countries: [
    Country(
      code: 'ZZ',
      name: 'Testland',
      dialCode: '999',
      nationalNumberLength: 9,
    ),
  ],
  carriers: [
    Carrier(
      id: 'c1',
      name: 'Test Carrier',
      countryCode: 'ZZ',
      prefixPattern: '^71',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerWith({
    required Future<AppConfig> Function() config,
    AuthRepository? auth,
  }) {
    return ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      configRepositoryProvider.overrideWithValue(_FakeConfigRepository(config)),
      if (auth != null) authRepositoryProvider.overrideWithValue(auth),
    ]);
  }

  Widget appFor(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const PhoneEntryScreen(),
        routes: {
          AppRoutes.otp: (_) => const Scaffold(body: Text('otp-screen')),
        },
      ),
    );
  }

  testWidgets('shows the form, suggests a network, enables continue', (tester) async {
    final container = containerWith(config: () async => _testConfig);
    addTearDown(container.dispose);
    await container.read(appConfigProvider.notifier).load();

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    expect(find.text('Enter your business phone number'), findsOneWidget);
    expect(find.textContaining('+999'), findsWidgets);

    ElevatedButton button() =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField), '712345678');
    await tester.pump();

    expect(find.text('Likely network: Test Carrier'), findsOneWidget);
    expect(button().onPressed, isNotNull);
  });

  testWidgets('sends the international number and opens the next screen', (tester) async {
    final auth = _FakeAuthRepository();
    final container = containerWith(config: () async => _testConfig, auth: auth);
    addTearDown(container.dispose);
    await container.read(appConfigProvider.notifier).load();

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '0712345678');
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(auth.sentTo, '+999712345678');
    expect(find.text('otp-screen'), findsOneWidget);
  });

  testWidgets('says plainly when the server cannot be reached', (tester) async {
    final container = containerWith(
      config: () async => throw const ApiException(kind: ApiErrorKind.network),
    );
    addTearDown(container.dispose);
    await container.read(appConfigProvider.notifier).load();

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    expect(find.text(translations['en']!.t('error.network')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
