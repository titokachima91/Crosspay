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
  _FakeAuthRepository(this._onSubmit) : super(Dio());

  final Future<KycStatus> Function() _onSubmit;

  @override
  Future<OtpChallenge> requestOtp(String phone) async => OtpChallenge(
        codeLength: 4,
        resendAfterSeconds: 30,
        expiresInSeconds: 300,
        requestedAt: DateTime.now(),
      );

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async =>
      const AuthSession(accessToken: 'test-token', profileComplete: false);

  @override
  Future<KycStatus> submitKyc({
    required String businessName,
    required String hubId,
    required String idNumber,
  }) =>
      _onSubmit();
}

class _MemoryTokenStorage implements TokenStorage {
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> delete() async => token = null;
}

Future<void> _signIn(ProviderContainer container) async {
  final notifier = container.read(authProvider.notifier);
  await notifier.requestOtp('+999712345678');
  await notifier.verifyOtp('1234');
}

void main() {
  test('accepted details keep the user signed in with the KYC status', () async {
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(
        _FakeAuthRepository(() async => KycStatus.pending),
      ),
      tokenStorageProvider.overrideWithValue(_MemoryTokenStorage()),
    ]);
    addTearDown(container.dispose);
    await _signIn(container);

    final ok = await container.read(authProvider.notifier).submitKyc(
          businessName: 'Test Trading',
          hubId: 'h1',
          idNumber: 'TEST-ID-1',
        );

    final state = container.read(authProvider);
    expect(ok, true);
    expect(state.status, AuthStatus.signedIn);
    expect(state.kycStatus, KycStatus.pending);
    expect(state.profileComplete, true);
  });

  test('a rejection keeps the user signed in and reports the code', () async {
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(
        _FakeAuthRepository(
          () async => throw const ApiException(
            kind: ApiErrorKind.client,
            statusCode: 422,
            code: 'ID_NUMBER_INVALID',
          ),
        ),
      ),
      tokenStorageProvider.overrideWithValue(_MemoryTokenStorage()),
    ]);
    addTearDown(container.dispose);
    await _signIn(container);

    final ok = await container.read(authProvider.notifier).submitKyc(
          businessName: 'Test Trading',
          hubId: 'h1',
          idNumber: 'TEST-ID-1',
        );

    final state = container.read(authProvider);
    expect(ok, false);
    expect(state.status, AuthStatus.signedIn);
    expect(state.errorCode, 'ID_NUMBER_INVALID');
    expect(state.kycStatus, isNull);
    expect(state.profileComplete, false);
  });

  test('if the session ends during submission, the sign-out is kept', () async {
    late final ProviderContainer container;
    container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(
        _FakeAuthRepository(() async {
          await container.read(authProvider.notifier).signOut();
          throw const ApiException(kind: ApiErrorKind.unauthorized);
        }),
      ),
      tokenStorageProvider.overrideWithValue(_MemoryTokenStorage()),
    ]);
    addTearDown(container.dispose);
    await _signIn(container);

    final ok = await container.read(authProvider.notifier).submitKyc(
          businessName: 'Test Trading',
          hubId: 'h1',
          idNumber: 'TEST-ID-1',
        );

    expect(ok, false);
    expect(container.read(authProvider).status, AuthStatus.signedOut);
    expect(container.read(authProvider).accessToken, isNull);
  });
}
