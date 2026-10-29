import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/user_model.dart';

enum AuthStatus { signedOut, otpPending, signedIn }

class AuthState {
  const AuthState({
    this.status = AuthStatus.signedOut,
    this.phone,
    this.user,
    this.errorMessage,
  });

  final AuthStatus status;
  final String? phone;
  final UserProfile? user;
  final String? errorMessage;

  AuthState copyWith({
    AuthStatus? status,
    String? phone,
    UserProfile? user,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      phone: phone ?? this.phone,
      user: user ?? this.user,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Holds who is signed in. The server calls arrive in F1.5 and F2.x; these
/// methods only move the state.
class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  void otpRequested(String phone) {
    state = AuthState(status: AuthStatus.otpPending, phone: phone);
  }

  void signedIn(UserProfile user) {
    state = AuthState(
      status: AuthStatus.signedIn,
      phone: user.phone,
      user: user,
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
