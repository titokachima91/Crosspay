import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/app.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final translations = await AppLocalizations.loadAll();

  // F5.3 — reopen in the language last chosen on this device. A device that
  // cannot answer simply starts in the default language.
  var language = 'en';
  try {
    final stored = await SecureLanguageStore().read();
    if (stored != null && AppLocalizations.supportedCodes.contains(stored)) {
      language = stored;
    }
  } catch (_) {
    // No stored choice available: keep 'en'.
  }

  runApp(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        localeCodeProvider.overrideWith(
          () => LocaleCodeNotifier(initial: language),
        ),
      ],
      child: const CrossPayApp(),
    ),
  );
}
