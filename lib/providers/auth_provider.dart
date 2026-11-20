import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/storage/token_storage.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';

enum AuthStatus {
  signedOut,
  requestingOtp,
  otpPending,
  verifyingOtp,
  signedIn,
  submittingKyc,
}

/// What the splash screen should do after checking the device for a session.
enum SessionRestore {
  /// No stored refresh token (or it is already revoked): ask for a code.
  noSession,

  /// A live session was restored and the profile was validated.
  restored,

  /// The token is valid, but business KYC was never completed.
  profileIncomplete,

  /// The server could not be reached. Keep the stored session for next time.
  unavailable,
}

class AuthState {
  const AuthState({
    this.status = AuthStatus.signedOut,
    this.phone,
    this.user,
    this.accessToken,
    this.profileComplete,
    this.isNewUser,
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

  /// True when the last OTP verification created a new account.
  final bool? isNewUser;

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
    bool? isNewUser,
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
      isNewUser: isNewUser ?? this.isNewUser,
      kycStatus: kycStatus ?? this.kycStatus,
      otpChallenge: otpChallenge ?? this.otpChallenge,
      errorKey: clearError ? null : (errorKey ?? this.errorKey),
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  /// One shared refresh call. Concurrent 401s await the same future.
  Future<String?>? _refreshing;

  /// Bumped by sign-out so a refresh that finishes late cannot revive the
  /// session.
  int _sessionEpoch = 0;

  @override
  AuthState build() => const AuthState();

  /// Exchanges the stored refresh token for a new token pair. Exactly one
  /// network call runs even when several requests hit a 401 together.
  Future<String?> refreshAccessToken() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final future = _performRefresh();
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<String?> _performRefresh() async {
    final epoch = _sessionEpoch;
    String? refreshToken;
    try {
      refreshToken = await ref.read(tokenStorageProvider).readRefreshToken();
    } catch (_) {
      return null;
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      // A signed-in session without a stored refresh token cannot be renewed.
      if (state.status != AuthStatus.signedOut) await signOut();
      return null;
    }

    try {
      final tokens =
          await ref.read(authRepositoryProvider).refresh(refreshToken);
      if (epoch != _sessionEpoch) return null;
      try {
        await ref
            .read(tokenStorageProvider)
            .writeAccessToken(tokens.accessToken);
        await ref
            .read(tokenStorageProvider)
            .writeRefreshToken(tokens.refreshToken);
      } catch (_) {
        // The session still works for this run; the next launch asks for a
        // code because the rotated refresh token could not be stored.
      }
      state = state.copyWith(
        status: AuthStatus.signedIn,
        accessToken: tokens.accessToken,
        clearError: true,
      );
      return tokens.accessToken;
    } on ApiException catch (e) {
      // Only a rejected refresh token is terminal. A network drop keeps the
      // session for the next attempt.
      if (e.statusCode == 401 && epoch == _sessionEpoch) {
        await signOut();
      }
      return null;
    }
  }

  /// F5.3 — called once at boot after `/config` is ready. Reads the stored
  /// refresh token, rotates it, and validates the profile so the splash can
  /// send a returning merchant straight to Home (or back to KYC).
  Future<SessionRestore> restoreSession() async {
    String? refreshToken;
    try {
      refreshToken = await ref.read(tokenStorageProvider).readRefreshToken();
    } catch (_) {
      return SessionRestore.noSession;
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      return SessionRestore.noSession;
    }

    final accessToken = await refreshAccessToken();
    if (accessToken == null) {
      // Terminal failures clear the stored refresh token; network failures
      // leave it in place for the next launch.
      String? remaining;
      try {
        remaining = await ref.read(tokenStorageProvider).readRefreshToken();
      } catch (_) {
        remaining = null;
      }
      return remaining == null
          ? SessionRestore.noSession
          : SessionRestore.unavailable;
    }

    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) return SessionRestore.restored;

    try {
      final profile = await ref.read(profileRepositoryProvider).fetch(config);
      state = state.copyWith(
        user: profile,
        profileComplete: true,
        kycStatus: profile.kycStatus,
      );
      return SessionRestore.restored;
    } on ApiException catch (e) {
      if (e.code == 'PROFILE_INCOMPLETE') {
        state = state.copyWith(
          profileComplete: false,
          kycStatus: KycStatus.notStarted,
        );
        return SessionRestore.profileIncomplete;
      }
      if (e.statusCode == 401) {
        await signOut();
        return SessionRestore.noSession;
      }
      // The session is valid; the profile call can be retried by Home.
      return SessionRestore.restored;
    }
  }

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
      final challenge =
          await ref.read(authRepositoryProvider).requestOtp(phone);
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
        await ref
            .read(tokenStorageProvider)
            .writeAccessToken(session.accessToken);
        await ref
            .read(tokenStorageProvider)
            .writeRefreshToken(session.refreshToken);
      } catch (_) {
        // The user stays signed in for this session even if the device
        // refuses to store the tokens.
      }

      state = AuthState(
        status: AuthStatus.signedIn,
        phone: phone,
        accessToken: session.accessToken,
        profileComplete: session.profileComplete,
        isNewUser: session.isNewUser,
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
    final storage = ref.read(tokenStorageProvider);
    String? refreshToken;
    try {
      refreshToken = await storage.readRefreshToken();
    } catch (_) {
      refreshToken = null;
    }

    // Local-first: clear the device immediately, then ask the server to revoke
    // the family in the background. An offline sign-out must still work.
    _sessionEpoch++;
    state = const AuthState();
    try {
      await storage.delete();
    } catch (_) {
      // Nothing more to do if the device cannot clear it.
    }

    if (refreshToken != null && refreshToken.isNotEmpty) {
      unawaited(
        ref.read(authRepositoryProvider).logout(refreshToken).catchError((_) {
          // The server-side token expires on its own if this best-effort
          // revocation cannot be delivered.
        }),
      );
    }
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
