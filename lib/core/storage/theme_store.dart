import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';

/// Where the chosen theme mode is remembered on this device. Same secure store
/// as the token and the language, so a device that cannot keep secrets also
/// cannot keep this: the app then starts in the default mode instead of failing.
abstract class ThemeStore {
  Future<AppThemeMode?> read();
  Future<void> write(AppThemeMode mode);
}

/// iPhone Keychain / Android Keystore (browser storage on web, as with the
/// token and language: development only).
class SecureThemeStore implements ThemeStore {
  SecureThemeStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const String _key = 'theme_mode';

  final FlutterSecureStorage _storage;

  @override
  Future<AppThemeMode?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return AppThemeMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppThemeMode.system,
    );
  }

  @override
  Future<void> write(AppThemeMode mode) =>
      _storage.write(key: _key, value: mode.name);
}

final themeStoreProvider = Provider<ThemeStore>((ref) => SecureThemeStore());
