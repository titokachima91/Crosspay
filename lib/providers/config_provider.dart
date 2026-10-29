import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/models/app_config_model.dart';

/// "unavailable" means the server has not been reached yet. Screens that need
/// currencies, hubs or rails must say so plainly instead of showing blanks.
enum ConfigStatus { unavailable, loading, ready, error }

class ConfigState {
  const ConfigState({
    this.status = ConfigStatus.unavailable,
    this.config = const AppConfig(),
    this.errorMessage,
  });

  final ConfigStatus status;
  final AppConfig config;
  final String? errorMessage;
}

class ConfigNotifier extends Notifier<ConfigState> {
  @override
  ConfigState build() => const ConfigState();

  void loading() => state = const ConfigState(status: ConfigStatus.loading);

  void loaded(AppConfig config) =>
      state = ConfigState(status: ConfigStatus.ready, config: config);

  void failed(String message) => state =
      ConfigState(status: ConfigStatus.error, errorMessage: message);
}

final appConfigProvider =
    NotifierProvider<ConfigNotifier, ConfigState>(ConfigNotifier.new);
