import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/repositories/config_repository.dart';

/// "unavailable" means the server has not been reached yet. Screens that need
/// currencies, hubs or rails must say so plainly instead of showing blanks.
enum ConfigStatus { unavailable, loading, ready, error }

class ConfigState {
  const ConfigState({
    this.status = ConfigStatus.unavailable,
    this.config = const AppConfig(),
    this.errorKey,
  });

  final ConfigStatus status;
  final AppConfig config;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class ConfigNotifier extends Notifier<ConfigState> {
  @override
  ConfigState build() => const ConfigState();

  Future<void> load() async {
    state = const ConfigState(status: ConfigStatus.loading);
    try {
      final config = await ref.read(configRepositoryProvider).fetch();
      state = ConfigState(status: ConfigStatus.ready, config: config);
    } on ApiException catch (e) {
      state = ConfigState(status: ConfigStatus.error, errorKey: e.messageKey);
    }
  }
}

final appConfigProvider =
    NotifierProvider<ConfigNotifier, ConfigState>(ConfigNotifier.new);
