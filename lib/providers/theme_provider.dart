import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, AppThemeMode>(
  (ref) => ThemeModeNotifier(ref.read(themeStoreProvider)),
);

class ThemeModeNotifier extends StateNotifier<AppThemeMode> {
  final ThemeStore _store;

  ThemeModeNotifier(this._store) : super(AppThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    try {
      final stored = await _store.read();
      if (stored != null) state = stored;
    } catch (_) {
      // Keep system default.
    }
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    await _store.write(mode);
    state = mode;
  }
}
