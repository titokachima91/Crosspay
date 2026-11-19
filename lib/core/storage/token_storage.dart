import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the sign-in tokens are kept on the device.
///
/// The access token authorises a single request. The refresh token is
/// long-lived, rotates on every use and is what "stay signed in" relies on.
/// Neither is ever available to the rest of the app as plain storage: only
/// the auth provider and the network layer read them.
abstract class TokenStorage {
  Future<String?> readAccessToken();
  Future<void> writeAccessToken(String token);

  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);

  Future<void> delete();
}

/// iPhone Keychain / Android Keystore. In a web browser this falls back to
/// ordinary browser storage, which is NOT a security boundary (fine for
/// development only).
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const String _accessKey = 'access_token';
  static const String _refreshKey = 'refresh_token';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readAccessToken() => _storage.read(key: _accessKey);

  @override
  Future<void> writeAccessToken(String token) =>
      _storage.write(key: _accessKey, value: token);

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _refreshKey, value: token);

  @override
  Future<void> delete() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }
}

final tokenStorageProvider = Provider<TokenStorage>(
  (ref) => SecureTokenStorage(),
);
