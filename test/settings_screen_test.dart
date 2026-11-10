import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/core/storage/theme_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/account/screens/settings_screen.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/theme_provider.dart';

/// Test-only stand-ins: no secure storage plugin is involved.
class _FakeThemeStore implements ThemeStore {
  AppThemeMode? stored;

  @override
  Future<AppThemeMode?> read() async => stored;

  @override
  Future<void> write(AppThemeMode mode) async => stored = mode;
}

class _FakeLanguageStore implements LanguageStore {
  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String code) async => stored = code;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  testWidgets('choosing a theme applies it and remembers it', (tester) async {
    final themeStore = _FakeThemeStore();
    final languageStore = _FakeLanguageStore();
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        themeStoreProvider.overrideWithValue(themeStore),
        languageStoreProvider.overrideWithValue(languageStore),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(container.read(themeModeProvider), AppThemeMode.dark);
    expect(themeStore.stored, AppThemeMode.dark);
  });

  testWidgets('choosing a language applies it and remembers it',
      (tester) async {
    final themeStore = _FakeThemeStore();
    final languageStore = _FakeLanguageStore();
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        themeStoreProvider.overrideWithValue(themeStore),
        languageStoreProvider.overrideWithValue(languageStore),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Kiswahili'));
    await tester.pump();

    expect(container.read(localeCodeProvider), 'sw');
    expect(languageStore.stored, 'sw');
  });

  testWidgets('settings opens the support screen', (tester) async {
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        themeStoreProvider.overrideWithValue(_FakeThemeStore()),
        languageStoreProvider.overrideWithValue(_FakeLanguageStore()),
      ],
    );
    addTearDown(container.dispose);

    await tester.binding.setSurfaceSize(const Size(500, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const SettingsScreen(),
          routes: {
            AppRoutes.support: (_) =>
                const Scaffold(body: Text('support-screen')),
          },
        ),
      ),
    );

    await tester.tap(find.text('Help & support'));
    await tester.pumpAndSettle();

    expect(find.text('support-screen'), findsOneWidget);
  });
}
