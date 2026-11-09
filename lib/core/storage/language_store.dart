import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// F5.3 — where the chosen language is remembered on this device. Same store
/// as the token, so a device that cannot keep secrets also cannot keep this:
/// the app then starts in the default language instead of failing.
abstract class LanguageStore {
  Future<String?> read();
  Future<void> write(String code);
}

/// iPhone Keychain / Android Keystore (browser storage on web, as with the
/// token: development only).
class SecureLanguageStore implements LanguageStore {
  SecureLanguageStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const String _key = 'locale_code';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String code) => _storage.write(key: _key, value: code);
}

final languageStoreProvider = Provider<LanguageStore>(
  (ref) => SecureLanguageStore(),
);
