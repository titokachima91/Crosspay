import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/beneficiary_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/repositories/beneficiary_repository.dart';

enum RecipientCheckStatus { idle, loading, ready, error }

class RecipientCheckState {
  const RecipientCheckState({
    this.status = RecipientCheckStatus.idle,
    this.check,
    this.errorKey,
    this.errorCode,
  });

  final RecipientCheckStatus status;

  /// Only ever the answer for the inputs currently on screen.
  final RecipientCheck? check;
  final String? errorKey;
  final String? errorCode;
}

/// How long to wait after the last keystroke before asking the server.
final recipientCheckDebounceProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 600),
);

/// Checks the recipient with the destination network as the form is filled.
/// Any change clears the old answer first, so a stale "match" can never
/// authorize a payment to details that were edited afterwards.
class RecipientCheckNotifier extends Notifier<RecipientCheckState> {
  Timer? _debounce;
  int _generation = 0;

  @override
  RecipientCheckState build() {
    ref.onDispose(() => _debounce?.cancel());
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        clear();
      }
    });
    return const RecipientCheckState();
  }

  void clear() {
    _debounce?.cancel();
    _generation++;
    state = const RecipientCheckState();
  }

  /// [account] is the normalized account to check; [accountReady] says whether
  /// it is complete enough to ask about. [name] may be empty.
  void inputsChanged({
    required PayoutRail? rail,
    required String account,
    required bool accountReady,
    required String name,
  }) {
    _debounce?.cancel();
    final generation = ++_generation;

    if (rail == null || !accountReady) {
      state = const RecipientCheckState();
      return;
    }

    state = const RecipientCheckState(status: RecipientCheckStatus.loading);
    _debounce = Timer(
      ref.read(recipientCheckDebounceProvider),
      () => _run(rail, account, name, generation),
    );
  }

  Future<void> _run(
    PayoutRail rail,
    String account,
    String name,
    int generation,
  ) async {
    try {
      final check = await ref.read(beneficiaryRepositoryProvider).check(
            rail: rail,
            account: account,
            name: name.isEmpty ? null : name,
          );
      if (generation != _generation) return;
      state = RecipientCheckState(
        status: RecipientCheckStatus.ready,
        check: check,
      );
    } on ApiException catch (e) {
      if (generation != _generation) return;
      state = RecipientCheckState(
        status: RecipientCheckStatus.error,
        errorKey: e.messageKey,
        errorCode: e.code,
      );
    }
  }
}

final recipientCheckProvider =
    NotifierProvider<RecipientCheckNotifier, RecipientCheckState>(
  RecipientCheckNotifier.new,
);
