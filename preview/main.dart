import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/app.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

import 'preview_banner.dart';
import 'preview_overrides.dart';

/// Run with:  flutter run -d chrome -t preview/main.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final translations = await AppLocalizations.loadAll();

  runApp(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWithValue(translations),
        ...previewOverrides(),
      ],
      child: CrossPayApp(
        builder: (context, child) =>
            PreviewBanner(child: child ?? const SizedBox()),
      ),
    ),
  );
}
