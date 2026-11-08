import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/trade_event_model.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

enum TimelineStatus {
  /// No trade loaded yet.
  idle,
  loading,
  ready,

  /// The endpoint does not exist yet: say so plainly, show no events.
  unavailable,
  error,
}

/// F4.1 — the status change timeline of one trade
/// (`GET /trades/{id}/history`). Events come from the server only; the app
/// never fills the gaps itself.
class TradeTimelineState {
  const TradeTimelineState({
    this.status = TimelineStatus.idle,
    this.events = const [],
    this.errorKey,
  });

  final TimelineStatus status;
  final List<TradeEvent> events;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class TradeTimelineNotifier extends Notifier<TradeTimelineState> {
  @override
  TradeTimelineState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.signedOut &&
          previous?.status != AuthStatus.signedOut) {
        state = const TradeTimelineState();
      }
    });
    return const TradeTimelineState();
  }

  Future<void> load(String tradeId) async {
    state = TradeTimelineState(
      status: TimelineStatus.loading,
      events: state.events,
    );
    try {
      final events = await ref.read(tradeRepositoryProvider).fetchTimeline(
            tradeId,
          );
      state = TradeTimelineState(status: TimelineStatus.ready, events: events);
    } on ApiException catch (e) {
      // "Not connected" is its own, plainer message than a generic failure.
      state = e.kind == ApiErrorKind.notConfigured
          ? const TradeTimelineState(status: TimelineStatus.unavailable)
          : TradeTimelineState(
              status: TimelineStatus.error,
              errorKey: e.messageKey,
            );
    }
  }
}

final tradeTimelineProvider =
    NotifierProvider<TradeTimelineNotifier, TradeTimelineState>(
  TradeTimelineNotifier.new,
);