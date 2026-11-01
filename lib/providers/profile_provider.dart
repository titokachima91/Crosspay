import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/profile_repository.dart';

enum ProfileStatus { unavailable, loading, ready, error }

class ProfileState {
  const ProfileState({
    this.status = ProfileStatus.unavailable,
    this.profile,
    this.errorKey,
  });

  final ProfileStatus status;
  final UserProfile? profile;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class ProfileNotifier extends Notifier<ProfileState> {
  @override
  ProfileState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        state = const ProfileState();
      }
    });
    return const ProfileState();
  }

  /// Needs the server config first (the profile refers to it by code).
  Future<void> load() async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const ProfileState();
      return;
    }

    state = ProfileState(status: ProfileStatus.loading, profile: state.profile);
    try {
      final profile = await ref.read(profileRepositoryProvider).fetch(config);
      state = ProfileState(status: ProfileStatus.ready, profile: profile);
    } on ApiException catch (e) {
      state = ProfileState(status: ProfileStatus.error, errorKey: e.messageKey);
    }
  }
}

final profileProvider =
    NotifierProvider<ProfileNotifier, ProfileState>(ProfileNotifier.new);
