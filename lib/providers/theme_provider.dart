import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/storage/theme_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';

/// The theme mode the user selected: light, dark, or follow the device.
///
/// `main()` reads the stored choice before the first frame and injects it with
/// [themeModeProvider.overrideWith], so the app opens in the right theme
/// without a flash. The notifier also loads from the store when it was not
/// seeded (preview app and tests).
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, AppThemeMode>(
  (ref) => ThemeModeNotifier(ref.read(themeStoreProvider)),
);

class ThemeModeNotifier extends StateNotifier<AppThemeMode> {
  ThemeModeNotifier(
    this._store, {
    AppThemeMode? initial,
  }) : super(initial ?? AppThemeMode.system) {
    if (initial == null) _load();
  }

  final ThemeStore _store;
  bool _changed = false;

  Future<void> _load() async {
    try {
      final stored = await _store.read();
      if (stored != null && !_changed) state = stored;
    } catch (_) {
      // Keep the system default: the device could not read the preference.
    }
  }

  /// Applies the choice immediately, then remembers it. A device that cannot
  /// write the preference still switches for this session.
  Future<void> setThemeMode(AppThemeMode mode) async {
    _changed = true;
    state = mode;
    try {
      await _store.write(mode);
    } catch (_) {
      // Nothing else to do: the choice lasts for this session only.
    }
  }
}
