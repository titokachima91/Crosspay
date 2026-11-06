import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/shell/main_shell_screen.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

import '../preview/preview_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  testWidgets('the four tabs switch, and Home loads the preview data', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      estimateDebounceProvider.overrideWithValue(Duration.zero),
      ...previewOverrides(latency: Duration.zero),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light, home: const MainShellScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Available today'), findsOneWidget);

    await tester.tap(find.text('Ledger'));
    await tester.pumpAndSettle();
    expect(find.text('Next: F4.1 ledger (temporary tab)'), findsOneWidget);

    await tester.tap(find.text('Rates'));
    await tester.pumpAndSettle();
    expect(find.text('Next: F4.2 rates (temporary tab)'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Transaction history'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Available today'), findsOneWidget);
  });
}
