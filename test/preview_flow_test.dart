import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/app.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

import '../preview/preview_banner.dart';
import '../preview/preview_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  testWidgets('the preview walks from the splash screen to the identity form', (tester) async {
    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      ...previewOverrides(latency: Duration.zero),
    ]);
    addTearDown(container.dispose);

    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CrossPayApp(
          builder: (context, child) =>
              PreviewBanner(child: child ?? const SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Splash: banner and simulated corridors.
    expect(find.textContaining('PREVIEW'), findsOneWidget);
    expect(find.textContaining('TZS'), findsWidgets);

    // Phone: a number with a recognised prefix.
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '712345678');
    await tester.pump();
    expect(
      find.text('Likely network: Preview Network A (Tanzania)'),
      findsOneWidget,
    );

    // Code: the simulated SMS code.
    await tester.tap(find.text('Continue with SMS OTP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Verify phone number'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1234');
    await tester.pump();
    await tester.tap(find.text('Verify and proceed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Identity: a person by default.
    expect(find.text('Verify your identity'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
