import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/onboarding/screens/otp_verification_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

// Test stand-ins and inputs only. Not app code or app data.
class _FakeConfigRepository extends ConfigRepository {
  _FakeConfigRepository() : super(Dio());

  @override
  Future<AppConfig> fetch() async => const AppConfig(
        currencies: [Currency(code: 'AAA', name: 'Alpha', countryCode: 'ZZ', decimals: 2)],
        countries: [
          Country(
            code: 'ZZ',
            name: 'Testland',
            dialCode: '999',
            nationalNumberLength: 9,
          ),
        ],
      );
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({required this.firstRequestedAt, this.onVerify})
      : super(Dio());

  final DateTime firstRequestedAt;
  final Future<AuthSession> Function(String phone, String code)? onVerify;
  int requests = 0;

  @override
  Future<OtpChallenge> requestOtp(String phone) async {
    requests++;
    return OtpChallenge(
      codeLength: 4,
      resendAfterSeconds: 30,
      expiresInSeconds: 300,
      requestedAt: requests == 1 ? firstRequestedAt : DateTime.now(),
    );
  }

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) =>
      onVerify!(phone, code);
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

  Future<ProviderContainer> readyContainer(
    _FakeAuthRepository auth,
    _MemoryTokenStorage storage,
  ) async {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      configRepositoryProvider.overrideWithValue(_FakeConfigRepository()),
      authRepositoryProvider.overrideWithValue(auth),
      tokenStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(container.dispose);
    await container.read(appConfigProvider.notifier).load();
    await container.read(authProvider.notifier).requestOtp('+999712345678');
    return container;
  }

  Widget appFor(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const OtpVerificationScreen(),
        routes: {
          AppRoutes.kyc: (_) => const Scaffold(body: Text('kyc-screen')),
          AppRoutes.home: (_) => const Scaffold(body: Text('home-screen')),
        },
      ),
    );
  }

  ElevatedButton verifyButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.byType(ElevatedButton));

  // Never pumpAndSettle here: the resend countdown keeps scheduling frames.
  Future<void> tapVerify(WidgetTester tester) async {
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('shows the number, a countdown and enables verify at full length', (tester) async {
    final container = await readyContainer(
      _FakeAuthRepository(firstRequestedAt: DateTime.now()),
      _MemoryTokenStorage(),
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    expect(
      find.text('Enter the 4-digit verification code sent to +999 712 345 678'),
      findsOneWidget,
    );
    expect(find.textContaining('Resend code in 00:'), findsOneWidget);
    expect(verifyButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '482');
    await tester.pump();
    expect(verifyButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '4829');
    await tester.pump();
    expect(verifyButton(tester).onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a correct code stores the token and opens KYC for a new merchant', (tester) async {
    final storage = _MemoryTokenStorage();
    final container = await readyContainer(
      _FakeAuthRepository(
        firstRequestedAt: DateTime.now(),
        onVerify: (phone, code) async => const AuthSession(
          accessToken: 'test-token',
          profileComplete: false,
        ),
      ),
      storage,
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '4829');
    await tester.pump();
    await tapVerify(tester);

    expect(find.text('kyc-screen'), findsOneWidget);
    expect(storage.token, 'test-token');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a correct code opens Home when the profile is complete', (tester) async {
    final container = await readyContainer(
      _FakeAuthRepository(
        firstRequestedAt: DateTime.now(),
        onVerify: (phone, code) async => const AuthSession(
          accessToken: 'test-token',
          profileComplete: true,
        ),
      ),
      _MemoryTokenStorage(),
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '4829');
    await tester.pump();
    await tapVerify(tester);

    expect(find.text('home-screen'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wrong code shows a clear message and clears the boxes', (tester) async {
    final container = await readyContainer(
      _FakeAuthRepository(
        firstRequestedAt: DateTime.now(),
        onVerify: (phone, code) async => throw const ApiException(
          kind: ApiErrorKind.client,
          statusCode: 400,
          code: 'OTP_INVALID',
        ),
      ),
      _MemoryTokenStorage(),
    );

    await tester.pumpWidget(appFor(container));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '0000');
    await tester.pump();
    await tapVerify(tester);

    expect(
      find.text('That code is not correct. Please check and try again.'),
      findsOneWidget,
    );
    expect(verifyButton(tester).onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resend appears when the wait is over and restarts the countdown', (tester) async {
    final auth = _FakeAuthRepository(
      firstRequestedAt: DateTime.now().subtract(const Duration(seconds: 40)),
    );
    final container = await readyContainer(auth, _MemoryTokenStorage());

    await tester.pumpWidget(appFor(container));
    await tester.pump();

    expect(find.text('Resend code'), findsOneWidget);
    expect(find.textContaining('Resend code in'), findsNothing);

    await tester.tap(find.text('Resend code'));
    await tester.pump();
    await tester.pump();

    expect(auth.requests, 2);
    expect(find.textContaining('Resend code in 00:'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
