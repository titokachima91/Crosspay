import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/user_model.dart';

enum AuthStatus { signedOut, otpPending, signedIn }

class AuthState {
  const AuthState({
    this.status = AuthStatus.signedOut,
    this.phone,
    this.user,
    this.accessToken,
    this.errorMessage,
  });

  final AuthStatus status;
  final String? phone;
  final UserProfile? user;

  /// JWT. Held in memory for now; secure on-device storage arrives in F2.3.
  final String? accessToken;
  final String? errorMessage;

  AuthState copyWith({
    AuthStatus? status,
    String? phone,
    UserProfile? user,
    String? accessToken,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      phone: phone ?? this.phone,
      user: user ?? this.user,
      accessToken: accessToken ?? this.accessToken,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Holds who is signed in. The server calls arrive in F2.x; these methods
/// only move the state.
class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  void otpRequested(String phone) {
    state = AuthState(status: AuthStatus.otpPending, phone: phone);
  }

  void signedIn(UserProfile user, String accessToken) {
    state = AuthState(
      status: AuthStatus.signedIn,
      phone: user.phone,
      user: user,
      accessToken: accessToken,
    );
  }

  void failed(String message) {
    state = state.copyWith(errorMessage: message);
  }

  void signOut() {
    state = const AuthState();
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
