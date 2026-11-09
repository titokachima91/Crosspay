import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/storage/theme_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/theme_provider.dart';

/// Test-only stand-in: no secure storage plugin is involved.
class _FakeThemeStore implements ThemeStore {
  _FakeThemeStore([this.stored]);

  AppThemeMode? stored;
  bool failWrites = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<AppThemeMode?> read() async {
    reads++;
    return stored;
  }

  @override
  Future<void> write(AppThemeMode mode) async {
    writes++;
    if (failWrites) throw StateError('storage unavailable');
    stored = mode;
  }
}

void main() {
  group('theme preference', () {
    test('defaults to system when nothing is stored', () async {
      final store = _FakeThemeStore();
      final container = ProviderContainer(
        overrides: [themeStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), AppThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(store.reads, 1);
      expect(container.read(themeModeProvider), AppThemeMode.system);
    });

    test('opens in the stored mode', () async {
      final store = _FakeThemeStore(AppThemeMode.dark);
      final container = ProviderContainer(
        overrides: [themeStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), AppThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    });

    test('an injected initial mode skips the store read', () async {
      final store = _FakeThemeStore(AppThemeMode.light);
      final container = ProviderContainer(
        overrides: [
          themeStoreProvider.overrideWithValue(store),
          themeModeProvider.overrideWith(
            (ref) => ThemeModeNotifier(
              ref.read(themeStoreProvider),
              initial: AppThemeMode.dark,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), AppThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      expect(store.reads, 0);
    });

    test('changing the mode updates state and persists it', () async {
      final store = _FakeThemeStore();
      final container = ProviderContainer(
        overrides: [themeStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      await container
          .read(themeModeProvider.notifier)
          .setThemeMode(AppThemeMode.light);

      expect(container.read(themeModeProvider), AppThemeMode.light);
      expect(store.stored, AppThemeMode.light);
      expect(store.writes, 1);
    });

    test('a storage failure still applies the mode for this session', () async {
      final store = _FakeThemeStore()..failWrites = true;
      final container = ProviderContainer(
        overrides: [themeStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      await container
          .read(themeModeProvider.notifier)
          .setThemeMode(AppThemeMode.dark);

      expect(container.read(themeModeProvider), AppThemeMode.dark);
    });
  });
}
