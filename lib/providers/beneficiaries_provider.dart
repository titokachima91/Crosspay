import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/app_config_model.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';

enum BeneficiariesStatus { unavailable, loading, ready, error }

class BeneficiariesState {
  const BeneficiariesState({
    this.status = BeneficiariesStatus.unavailable,
    this.items = const [],
    this.errorKey,
    this.saving = false,
  });

  final BeneficiariesStatus status;
  final List<Beneficiary> items;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;

  /// True while a save or a delete is in flight (buttons go quiet).
  final bool saving;
}

class BeneficiariesNotifier extends Notifier<BeneficiariesState> {
  @override
  BeneficiariesState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        state = const BeneficiariesState();
      }
    });
    return const BeneficiariesState();
  }

  Future<void> load() async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const BeneficiariesState();
      return;
    }

    state = BeneficiariesState(
      status: BeneficiariesStatus.loading,
      items: state.items,
    );
    try {
      final items = await ref.read(beneficiaryRepositoryProvider).list(config);
      state = BeneficiariesState(
        status: BeneficiariesStatus.ready,
        items: items,
      );
    } on ApiException catch (e) {
      state = BeneficiariesState(
        status: BeneficiariesStatus.error,
        errorKey: e.messageKey,
      );
    }
  }

  /// F5.2 — adds a recipient, then reloads the list. False means the server
  /// refused; [errorKey] carries why.
  Future<bool> add({
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) {
    return _mutate(
      (repo, config) => repo.add(
        config: config,
        rail: rail,
        name: name,
        accountOrPhone: accountOrPhone,
      ),
    );
  }

  /// F5.2 — edits a saved recipient, then reloads the list.
  Future<bool> update({
    required String id,
    required PayoutRail rail,
    required String name,
    required String accountOrPhone,
  }) {
    return _mutate(
      (repo, config) => repo.update(
        config: config,
        id: id,
        rail: rail,
        name: name,
        accountOrPhone: accountOrPhone,
      ),
    );
  }

  /// F5.2 — removes a saved recipient, then reloads the list.
  Future<bool> remove(String id) {
    return _mutate((repo, config) => repo.remove(id));
  }

  /// Runs one write against the server and reloads on success. The list is
  /// never edited locally: what is shown is always what the server returned.
  Future<bool> _mutate(
    Future<Object?> Function(BeneficiaryRepository, AppConfig) write,
  ) async {
    final config = ref.read(appConfigProvider).config;
    if (config.isEmpty) {
      state = const BeneficiariesState();
      return false;
    }

    state = BeneficiariesState(
      status: state.status,
      items: state.items,
      saving: true,
    );
    try {
      await write(ref.read(beneficiaryRepositoryProvider), config);
    } on ApiException catch (e) {
      state = BeneficiariesState(
        status: state.status,
        items: state.items,
        errorKey: e.messageKey,
      );
      return false;
    }

    await load();
    return true;
  }
}

final beneficiariesProvider =
    NotifierProvider<BeneficiariesNotifier, BeneficiariesState>(
  BeneficiariesNotifier.new,
);
