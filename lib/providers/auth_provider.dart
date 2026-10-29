import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

enum AuthStatus { signedOut, requestingOtp, otpPending, signedIn }

class AuthState {
  const AuthState({
    this.status = AuthStatus.signedOut,
    this.phone,
    this.user,
    this.accessToken,
    this.otpChallenge,
    this.errorKey,
  });

  final AuthStatus status;

  /// International format, e.g. "+<calling code><number>".
  final String? phone;
  final UserProfile? user;

  /// JWT. Held in memory for now; secure on-device storage arrives in F2.3.
  final String? accessToken;
  final OtpChallenge? otpChallenge;

  /// Localization key describing the last failure, e.g. 'error.network'.
  final String? errorKey;

  AuthState copyWith({
    AuthStatus? status,
    String? phone,
    UserProfile? user,
    String? accessToken,
    OtpChallenge? otpChallenge,
    String? errorKey,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      phone: phone ?? this.phone,
      user: user ?? this.user,
      accessToken: accessToken ?? this.accessToken,
      otpChallenge: otpChallenge ?? this.otpChallenge,
      errorKey: clearError ? null : (errorKey ?? this.errorKey),
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  /// Asks the server to send a code. Returns true when the code was sent.
  Future<bool> requestOtp(String phone) async {
    state = AuthState(status: AuthStatus.requestingOtp, phone: phone);
    try {
      final challenge = await ref.read(authRepositoryProvider).requestOtp(phone);
      state = AuthState(
        status: AuthStatus.otpPending,
        phone: phone,
        otpChallenge: challenge,
      );
      return true;
    } on ApiException catch (e) {
      state = AuthState(
        status: AuthStatus.signedOut,
        phone: phone,
        errorKey: e.messageKey,
      );
      return false;
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  void signedIn(UserProfile user, String accessToken) {
    state = AuthState(
      status: AuthStatus.signedIn,
      phone: user.phone,
      user: user,
      accessToken: accessToken,
    );
  }

  void signOut() => state = const AuthState();
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
