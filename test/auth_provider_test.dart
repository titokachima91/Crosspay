import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

// Test stand-in only. Not app code.
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository(this._outcome) : super(Dio());

  final Future<OtpChallenge> Function(String phone) _outcome;

  @override
  Future<OtpChallenge> requestOtp(String phone) => _outcome(phone);
}

void main() {
  test('a sent code moves to otpPending and keeps the server timings', () async {
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(
        _FakeAuthRepository(
          (phone) async => OtpChallenge(
            codeLength: 4,
            resendAfterSeconds: 30,
            expiresInSeconds: 300,
            requestedAt: DateTime.now(),
          ),
        ),
      ),
    ]);
    addTearDown(container.dispose);

    final sent =
        await container.read(authProvider.notifier).requestOtp('+999712345678');

    final state = container.read(authProvider);
    expect(sent, true);
    expect(state.status, AuthStatus.otpPending);
    expect(state.phone, '+999712345678');
    expect(state.otpChallenge?.codeLength, 4);
    expect(state.errorKey, isNull);
  });

  test('a failure stays signed out and reports a translatable key', () async {
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(
        _FakeAuthRepository(
          (phone) async => throw const ApiException(kind: ApiErrorKind.network),
        ),
      ),
    ]);
    addTearDown(container.dispose);

    final sent =
        await container.read(authProvider.notifier).requestOtp('+999712345678');

    final state = container.read(authProvider);
    expect(sent, false);
    expect(state.status, AuthStatus.signedOut);
    expect(state.errorKey, 'error.network');

    container.read(authProvider.notifier).clearError();
    expect(container.read(authProvider).errorKey, isNull);
  });
}
