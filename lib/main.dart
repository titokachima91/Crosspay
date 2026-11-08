import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/app.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

final themeStoreProviderOverride =
    Provider<ThemeStore>((ref) => SecureThemeStore());

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final translations = await AppLocalizations.loadAll();

  // F5.3 — reopen in the language last chosen on this device.
  var language = 'en';
  try {
    final stored = await SecureLanguageStore().read();
    if (stored != null && AppLocalizations.supportedCodes.contains(stored)) {
      language = stored;
    }
  } catch (_) {
    // No stored choice available: keep 'en'.
  }

  // Theme preference — defaults to system.
  AppThemeMode themeMode = AppThemeMode.system;
  try {
    final storedTheme = await SecureThemeStore().read();
    if (storedTheme != null) themeMode = storedTheme;
  } catch (_) {
    // No stored choice: keep system.
  }

  runApp(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        localeCodeProvider.overrideWith(
          () => LocaleCodeNotifier(initial: language),
        ),
        themeStoreProviderOverride.overrideWithValue(
          SecureThemeStore(),
        ),
      ],
      child: CrossPayApp(themeMode: themeMode),
    ),
  );
}
