import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

// Test stand-ins only. Not app code.
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({this.onRequest, this.onVerify, this.onRefresh})
      : super(Dio());

  final Future<OtpChallenge> Function(String phone)? onRequest;
  final Future<AuthSession> Function(String phone, String code)? onVerify;
  final Future<TokenPair> Function(String refreshToken)? onRefresh;
  int refreshCalls = 0;

  @override
  Future<OtpChallenge> requestOtp(String phone) => onRequest!(phone);

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) =>
      onVerify!(phone, code);

  @override
  Future<TokenPair> refresh(String refreshToken) {
    refreshCalls++;
    return onRefresh!(refreshToken);
  }
}

class _MemoryTokenStorage implements TokenStorage {
  String? token;
  String? refreshToken;

  @override
  Future<String?> readAccessToken() async => token;

  @override
  Future<void> writeAccessToken(String value) async => token = value;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> writeRefreshToken(String value) async => refreshToken = value;

  @override
  Future<void> delete() async {
    token = null;
    refreshToken = null;
  }
}

OtpChallenge _challenge() => OtpChallenge(
      codeLength: 4,
      resendAfterSeconds: 30,
      expiresInSeconds: 300,
      requestedAt: DateTime.now(),
    );

const _phone = '+999712345678';

ProviderContainer _container(
  _FakeAuthRepository repo,
  _MemoryTokenStorage storage,
) {
  final container = ProviderContainer(overrides: [
    authRepositoryProvider.overrideWithValue(repo),
    tokenStorageProvider.overrideWithValue(storage),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a sent code moves to otpPending and keeps the server timings',
      () async {
    final container = _container(
      _FakeAuthRepository(onRequest: (_) async => _challenge()),
      _MemoryTokenStorage(),
    );

    final sent = await container.read(authProvider.notifier).requestOtp(_phone);

    final state = container.read(authProvider);
    expect(sent, true);
    expect(state.status, AuthStatus.otpPending);
    expect(state.phone, _phone);
    expect(state.otpChallenge?.codeLength, 4);
    expect(state.errorKey, isNull);
  });

  test('a failed first request stays signed out with a translatable error',
      () async {
    final container = _container(
      _FakeAuthRepository(
        onRequest: (_) async => throw const ApiException(
          kind: ApiErrorKind.client,
          code: 'RATE_LIMITED',
        ),
      ),
      _MemoryTokenStorage(),
    );

    final sent = await container.read(authProvider.notifier).requestOtp(_phone);

    final state = container.read(authProvider);
    expect(sent, false);
    expect(state.status, AuthStatus.signedOut);
    expect(state.errorKey, 'error.client');
    expect(state.errorCode, 'RATE_LIMITED');

    container.read(authProvider.notifier).clearError();
    expect(container.read(authProvider).errorKey, isNull);
    expect(container.read(authProvider).errorCode, isNull);
  });

  test('a failed resend keeps the code screen and its challenge', () async {
    var calls = 0;
    final container = _container(
      _FakeAuthRepository(
        onRequest: (_) async {
          calls++;
          if (calls == 1) return _challenge();
          throw const ApiException(kind: ApiErrorKind.timeout);
        },
      ),
      _MemoryTokenStorage(),
    );
    final notifier = container.read(authProvider.notifier);

    await notifier.requestOtp(_phone);
    final resent = await notifier.requestOtp(_phone);

    final state = container.read(authProvider);
    expect(resent, false);
    expect(state.status, AuthStatus.otpPending);
    expect(state.otpChallenge, isNotNull);
    expect(state.errorKey, 'error.timeout');
  });

  test('a correct code signs in and stores the token', () async {
    final storage = _MemoryTokenStorage();
    final container = _container(
      _FakeAuthRepository(
        onRequest: (_) async => _challenge(),
        onVerify: (phone, code) async => const AuthSession(
          accessToken: 'test-token',
          refreshToken: 'test-refresh',
          profileComplete: true,
        ),
      ),
      storage,
    );
    final notifier = container.read(authProvider.notifier);

    await notifier.requestOtp(_phone);
    final ok = await notifier.verifyOtp('1234');

    final state = container.read(authProvider);
    expect(ok, true);
    expect(state.status, AuthStatus.signedIn);
    expect(state.accessToken, 'test-token');
    expect(state.profileComplete, true);
    expect(storage.token, 'test-token');
    expect(storage.refreshToken, 'test-refresh');
  });

  test('a wrong code stays on the code screen and stores nothing', () async {
    final storage = _MemoryTokenStorage();
    final container = _container(
      _FakeAuthRepository(
        onRequest: (_) async => _challenge(),
        onVerify: (phone, code) async => throw const ApiException(
          kind: ApiErrorKind.client,
          statusCode: 400,
          code: 'OTP_INVALID',
        ),
      ),
      storage,
    );
    final notifier = container.read(authProvider.notifier);

    await notifier.requestOtp(_phone);
    final ok = await notifier.verifyOtp('0000');

    final state = container.read(authProvider);
    expect(ok, false);
    expect(state.status, AuthStatus.otpPending);
    expect(state.otpChallenge, isNotNull);
    expect(state.errorCode, 'OTP_INVALID');
    expect(storage.token, isNull);
  });

  test('signing out clears the session and the stored token', () async {
    final storage = _MemoryTokenStorage();
    final container = _container(
      _FakeAuthRepository(
        onRequest: (_) async => _challenge(),
        onVerify: (phone, code) async => const AuthSession(
          accessToken: 'test-token',
          refreshToken: 'test-refresh',
          profileComplete: false,
        ),
      ),
      storage,
    );
    final notifier = container.read(authProvider.notifier);

    await notifier.requestOtp(_phone);
    await notifier.verifyOtp('1234');
    await notifier.signOut();

    expect(container.read(authProvider).status, AuthStatus.signedOut);
    expect(container.read(authProvider).accessToken, isNull);
    expect(storage.token, isNull);
    expect(storage.refreshToken, isNull);
  });

  test('restoring rotates the stored tokens and signs the merchant in',
      () async {
    final storage = _MemoryTokenStorage()
      ..token = 'expired-access'
      ..refreshToken = 'refresh-1';
    final repo = _FakeAuthRepository(
      onRefresh: (token) async {
        expect(token, 'refresh-1');
        return const TokenPair(
          accessToken: 'access-2',
          refreshToken: 'refresh-2',
        );
      },
    );
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      tokenStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(container.dispose);

    final outcome =
        await container.read(authProvider.notifier).restoreSession();

    // No /config was loaded in this container, so profile validation is
    // deferred to Home; the token restore itself must succeed.
    expect(outcome, SessionRestore.restored);
    expect(container.read(authProvider).status, AuthStatus.signedIn);
    expect(container.read(authProvider).accessToken, 'access-2');
    expect(storage.token, 'access-2');
    expect(storage.refreshToken, 'refresh-2');
    expect(repo.refreshCalls, 1);
  });

  test('a rejected refresh signs out and clears both tokens', () async {
    final storage = _MemoryTokenStorage()
      ..token = 'expired-access'
      ..refreshToken = 'revoked-refresh';
    final repo = _FakeAuthRepository(
      onRefresh: (_) async => throw const ApiException(
        kind: ApiErrorKind.unauthorized,
        statusCode: 401,
        code: 'REFRESH_TOKEN_REUSED',
      ),
    );
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      tokenStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(container.dispose);

    final outcome =
        await container.read(authProvider.notifier).restoreSession();

    expect(outcome, SessionRestore.noSession);
    expect(container.read(authProvider).status, AuthStatus.signedOut);
    expect(storage.token, isNull);
    expect(storage.refreshToken, isNull);
  });

  test('an unreachable server keeps the session for the next attempt',
      () async {
    final storage = _MemoryTokenStorage()
      ..token = 'expired-access'
      ..refreshToken = 'refresh-1';
    final repo = _FakeAuthRepository(
      onRefresh: (_) async =>
          throw const ApiException(kind: ApiErrorKind.network),
    );
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      tokenStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(container.dispose);

    final outcome =
        await container.read(authProvider.notifier).restoreSession();

    expect(outcome, SessionRestore.unavailable);
    expect(storage.refreshToken, 'refresh-1');
  });

  test('concurrent refreshes share one rotation', () async {
    final storage = _MemoryTokenStorage()..refreshToken = 'refresh-1';
    final repo = _FakeAuthRepository(
      onRefresh: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const TokenPair(
          accessToken: 'access-2',
          refreshToken: 'refresh-2',
        );
      },
    );
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      tokenStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(authProvider.notifier);

    final results = await Future.wait([
      notifier.refreshAccessToken(),
      notifier.refreshAccessToken(),
      notifier.refreshAccessToken(),
    ]);

    expect(repo.refreshCalls, 1);
    expect(results, ['access-2', 'access-2', 'access-2']);
    expect(storage.refreshToken, 'refresh-2');
  });
}
