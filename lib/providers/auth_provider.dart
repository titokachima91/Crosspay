import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

enum AuthStatus {
  signedOut,
  requestingOtp,
  otpPending,
  verifyingOtp,
  signedIn,
  submittingKyc,
}

class AuthState {
  const AuthState({
    this.status = AuthStatus.signedOut,
    this.phone,
    this.user,
    this.accessToken,
    this.profileComplete,
    this.kycStatus,
    this.otpChallenge,
    this.errorKey,
    this.errorCode,
  });

  final AuthStatus status;

  /// International format, e.g. "+<calling code><number>".
  final String? phone;

  /// Loaded separately after sign-in (F3.1).
  final UserProfile? user;

  /// JWT, also saved to secure storage at sign-in.
  final String? accessToken;

  /// Whether business KYC is done. Known once the code is verified.
  final bool? profileComplete;

  /// Set after the business details were submitted (verified or pending).
  final KycStatus? kycStatus;
  final OtpChallenge? otpChallenge;

  /// Localization key for the last failure, e.g. 'error.network', and the
  /// server's error code (e.g. OTP_INVALID) for a more specific message.
  final String? errorKey;
  final String? errorCode;

  AuthState copyWith({
    AuthStatus? status,
    String? phone,
    UserProfile? user,
    String? accessToken,
    bool? profileComplete,
    KycStatus? kycStatus,
    OtpChallenge? otpChallenge,
    String? errorKey,
    String? errorCode,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      phone: phone ?? this.phone,
      user: user ?? this.user,
      accessToken: accessToken ?? this.accessToken,
      profileComplete: profileComplete ?? this.profileComplete,
      kycStatus: kycStatus ?? this.kycStatus,
      otpChallenge: otpChallenge ?? this.otpChallenge,
      errorKey: clearError ? null : (errorKey ?? this.errorKey),
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  /// Asks the server to send a code (also used for "resend").
  /// Returns true when the code was sent.
  Future<bool> requestOtp(String phone) async {
    // During a resend to the same number, keep the previous challenge so the
    // code screen does not lose its layout.
    final previous = state.phone == phone ? state.otpChallenge : null;
    state = AuthState(
      status: AuthStatus.requestingOtp,
      phone: phone,
      otpChallenge: previous,
    );

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
        status: previous == null ? AuthStatus.signedOut : AuthStatus.otpPending,
        phone: phone,
        otpChallenge: previous,
        errorKey: e.messageKey,
        errorCode: e.code,
      );
      return false;
    }
  }

  /// Sends the typed code. Returns true when the server accepted it.
  Future<bool> verifyOtp(String code) async {
    final phone = state.phone;
    if (phone == null) return false;

    state = state.copyWith(status: AuthStatus.verifyingOtp, clearError: true);

    try {
      final session = await ref
          .read(authRepositoryProvider)
          .verifyOtp(phone: phone, code: code);

      try {
        await ref.read(tokenStorageProvider).write(session.accessToken);
      } catch (_) {
        // The user stays signed in for this session even if the device
        // refuses to store the token.
      }

      state = AuthState(
        status: AuthStatus.signedIn,
        phone: phone,
        accessToken: session.accessToken,
        profileComplete: session.profileComplete,
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(
        status: AuthStatus.otpPending,
        errorKey: e.messageKey,
        errorCode: e.code,
      );
      return false;
    }
  }

  /// Sends the business details. The ID/TIN is passed straight through to the
  /// server and is never kept in state, stored, or logged here.
  /// Returns true when the server accepted it (verified or pending).
  Future<bool> submitKyc({
    required AccountType accountType,
    required String legalName,
    String? hubId,
    required String idNumber,
  }) async {
    state = state.copyWith(status: AuthStatus.submittingKyc, clearError: true);

    try {
      final kyc = await ref.read(authRepositoryProvider).submitKyc(
            accountType: accountType,
            legalName: legalName,
            hubId: hubId,
            idNumber: idNumber,
          );
      state = state.copyWith(
        status: AuthStatus.signedIn,
        kycStatus: kyc,
        profileComplete: true,
      );
      return true;
    } on ApiException catch (e) {
      // If the session ended meanwhile (for example a 401 signed the user
      // out), keep that outcome instead of overwriting it.
      if (state.status == AuthStatus.submittingKyc) {
        state = state.copyWith(
          status: AuthStatus.signedIn,
          errorKey: e.messageKey,
          errorCode: e.code,
        );
      }
      return false;
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  Future<void> signOut() async {
    state = const AuthState();
    try {
      await ref.read(tokenStorageProvider).delete();
    } catch (_) {
      // Nothing more to do if the device cannot clear it.
    }
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
