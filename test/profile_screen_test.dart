import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/account/screens/profile_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';

// Test inputs and stand-ins only. Not app data or app code.
const _tzs = Currency(
  code: 'TZS',
  name: 'Tanzanian Shilling',
  countryCode: 'TZ',
  decimals: 0,
);
const _config = AppConfig(currencies: [_tzs]);

class _ReadyConfig extends ConfigNotifier {
  _ReadyConfig(this._state);

  final ConfigState _state;

  @override
  ConfigState build() => _state;
}

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository(this._answer) : super(Dio());

  final Future<UserProfile> Function(AppConfig) _answer;

  @override
  Future<UserProfile> fetch(AppConfig config) => _answer(config);
}

UserProfile _profile(AppConfig config) => UserProfile(
      id: 'u1',
      phone: '+255712345678',
      displayName: 'Amina Yusuf',
      accountType: AccountType.personal,
      kycStatus: KycStatus.verified,
      limitCurrency: config.currencyByCode('TZS')!,
      dailyLimitMinor: 10000000,
      dailyUsedMinor: 2000000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerFor(
    _FakeProfileRepository repo, {
    bool withConfig = true,
  }) =>
      ProviderContainer(overrides: [
        profileRepositoryProvider.overrideWithValue(repo),
        translationsProvider.overrideWithValue(translations),
        if (withConfig)
          appConfigProvider.overrideWith(
            () => _ReadyConfig(
              const ConfigState(status: ConfigStatus.ready, config: _config),
            ),
          ),
      ]);

  Future<void> open(WidgetTester tester, ProviderContainer container) async {
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light, home: const ProfileScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  }

  testWidgets('the profile and the daily limit bar are shown', (tester) async {
    final container = containerFor(
      _FakeProfileRepository((config) async => _profile(config)),
    );
    await open(tester, container);

    expect(find.text('Amina Yusuf'), findsOneWidget);
    expect(find.text('+255712345678'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text("TODAY'S LIMIT"), findsOneWidget);
    expect(
      find.text('TZS 2,000,000 of TZS 10,000,000 used'),
      findsOneWidget,
    );
    expect(find.text('TZS 8,000,000 left today'), findsOneWidget);

    await finish(tester, container);
  });

  testWidgets('a failure keeps the reason on screen', (tester) async {
    final container = containerFor(
      _FakeProfileRepository(
        (config) async => throw const ApiException(kind: ApiErrorKind.network),
      ),
    );
    await open(tester, container);

    expect(
      find.text('No connection. Please check your internet and try again.'),
      findsOneWidget,
    );

    await finish(tester, container);
  });

  testWidgets('no config yet means the screen says it is not connected',
      (tester) async {
    final container = containerFor(
      _FakeProfileRepository((config) async => _profile(config)),
      withConfig: false,
    );
    await open(tester, container);

    expect(find.text('Your profile is not connected yet.'), findsOneWidget);

    await finish(tester, container);
  });
}