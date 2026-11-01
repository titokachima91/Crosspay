import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
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
  });

  final BeneficiariesStatus status;
  final List<Beneficiary> items;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
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
}

final beneficiariesProvider =
    NotifierProvider<BeneficiariesNotifier, BeneficiariesState>(
  BeneficiariesNotifier.new,
);
