import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/shell/main_shell_screen.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/estimate_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

import '../preview/preview_overrides.dart';

class _ReadyConfig extends ConfigNotifier {
  _ReadyConfig(this._state);

  final ConfigState _state;

  @override
  ConfigState build() => _state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  setUp(() {
    // F5.3 PIN gate: PinManager reads secure storage through a platform
    // channel that has no responder under test, so the future never
    // completes and pumpAndSettle hangs. The plugin's own @visibleForTesting
    // hook backs reads with an in-memory map instead: empty map -> no PIN ->
    // the gate opens instantly. Re-set per test so state never leaks.
    FlutterSecureStorage.setMockInitialValues(const {});
  });

  testWidgets('the four tabs switch, and Home loads the preview data',
      (tester) async {
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
        child:
            MaterialApp(theme: AppTheme.light, home: const MainShellScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Available today'), findsOneWidget);

    await tester.tap(find.text('Ledger'));
    await tester.pumpAndSettle();
    // F4.1 — the Ledger tab is the real history screen now.
    expect(find.text('History'), findsOneWidget);

    await tester.tap(find.text('Rates'));
    await tester.pumpAndSettle();
    // F4.2 — the Rates tab is the real market depth screen now.
    expect(find.text('Market depth'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Transaction history'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Available today'), findsOneWidget);
  });

  testWidgets('shows the active server banner in the selected language',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime.now();
    final config = AppConfig(
      currencies: previewConfig.currencies,
      hubs: previewConfig.hubs,
      payoutRails: previewConfig.payoutRails,
      countries: previewConfig.countries,
      carriers: previewConfig.carriers,
      banners: [
        AppBanner(
          id: 'active',
          messageEn: 'Scheduled maintenance on Saturday',
          messageSw: 'Matengenezo yaliyopangwa Jumamosi',
          severity: BannerSeverity.warning,
          startsAt: now.subtract(const Duration(hours: 1)),
          endsAt: now.add(const Duration(days: 1)),
        ),
        AppBanner(
          id: 'ended',
          messageEn: 'An old notice that should be hidden',
          messageSw: 'Taarifa ya zamani inayopaswa kufichwa',
          severity: BannerSeverity.info,
          startsAt: now.subtract(const Duration(days: 2)),
          endsAt: now.subtract(const Duration(days: 1)),
        ),
      ],
    );

    final container = ProviderContainer(overrides: [
      translationsProvider.overrideWithValue(translations),
      estimateDebounceProvider.overrideWithValue(Duration.zero),
      appConfigProvider.overrideWith(
        () => _ReadyConfig(
            ConfigState(status: ConfigStatus.ready, config: config)),
      ),
      ...previewOverrides(latency: Duration.zero),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child:
            MaterialApp(theme: AppTheme.light, home: const MainShellScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Scheduled maintenance on Saturday'), findsOneWidget);
    expect(find.text('An old notice that should be hidden'), findsNothing);

    await container.read(localeCodeProvider.notifier).setLanguage('sw');
    await tester.pumpAndSettle();
    expect(find.text('Matengenezo yaliyopangwa Jumamosi'), findsOneWidget);
    expect(find.text('Scheduled maintenance on Saturday'), findsNothing);

    // Dispose the shell so the window-boundary timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });
}
