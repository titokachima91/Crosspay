import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/app.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/core/storage/theme_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/theme_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final translations = await AppLocalizations.loadAll();

  final languageStore = SecureLanguageStore();
  final themeStore = SecureThemeStore();

  // F5.3 — reopen in the language last chosen on this device.
  var language = 'en';
  try {
    final stored = await languageStore.read();
    if (stored != null && AppLocalizations.supportedCodes.contains(stored)) {
      language = stored;
    }
  } catch (_) {
    // No stored choice available: keep 'en'.
  }

  // Theme preference — defaults to following the device.
  var themeMode = AppThemeMode.system;
  try {
    final stored = await themeStore.read();
    if (stored != null) themeMode = stored;
  } catch (_) {
    // No stored choice available: keep the system default.
  }

  runApp(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        languageStoreProvider.overrideWithValue(languageStore),
        themeStoreProvider.overrideWithValue(themeStore),
        localeCodeProvider.overrideWith(
          () => LocaleCodeNotifier(initial: language),
        ),
        themeModeProvider.overrideWith(
          (ref) => ThemeModeNotifier(
            ref.read(themeStoreProvider),
            initial: themeMode,
          ),
        ),
      ],
      child: const CrossPayApp(),
    ),
  );
}
