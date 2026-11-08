import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/repositories/trade_repository.dart';

/// F4.1 — CSV export (`GET /trades/export`). The app asks for a one-time
/// link and hands it over; it never builds a file on the device.
class TradeExportState {
  const TradeExportState({this.busy = false, this.ticket, this.errorKey});

  final bool busy;

  /// The link the server issued, once it answered.
  final ExportTicket? ticket;

  /// Localization key describing the failure, e.g. 'error.network'.
  final String? errorKey;
}

class TradeExportNotifier extends Notifier<TradeExportState> {
  @override
  TradeExportState build() => const TradeExportState();

  /// Asks the server for an export link. Returns the ticket, or null when the
  /// server could not provide one (the screen then says so plainly).
  Future<ExportTicket?> request() async {
    if (state.busy) return null;
    state = const TradeExportState(busy: true);
    try {
      final ticket = await ref.read(tradeRepositoryProvider).requestExport();
      state = TradeExportState(ticket: ticket);
      return ticket;
    } on ApiException catch (e) {
      state = TradeExportState(errorKey: e.messageKey);
      return null;
    }
  }
}

final tradeExportProvider =
    NotifierProvider<TradeExportNotifier, TradeExportState>(
  TradeExportNotifier.new,
);