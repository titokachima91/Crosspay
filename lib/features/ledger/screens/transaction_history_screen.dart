import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/date_format.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_export_provider.dart';
import 'package:crosspay_app/providers/trade_history_provider.dart';

/// Date windows offered above the list. [days] is null for "all time".
enum HistoryRange {
  all('ledger.range.all', null),
  last7('ledger.range.last_7', 7),
  last30('ledger.range.last_30', 30),
  last90('ledger.range.last_90', 90);

  const HistoryRange(this.labelKey, this.days);

  /// Translation key for the chip label.
  final String labelKey;
  final int? days;

  /// Whether [createdAt] falls inside this window. "All time" never
  /// filters a row out. Compared as instants, so UTC rows from the
  /// server and the device clock line up.
  bool includes(DateTime createdAt, DateTime now) {
    final days = this.days;
    if (days == null) return true;
    return createdAt.isAfter(now.subtract(Duration(days: days)));
  }
}

/// F4.1 Transaction History — searchable, filterable list of the user's trades.
///
/// Reads ONLY from [tradeHistoryProvider] (server data). When the
/// endpoint is unavailable the screen says so plainly ("not
/// connected") — never fake data in lib/ (product rule 2 & 5).
/// Search, status and date-window filters run on the device over the
/// server-provided rows; the server stays the source of truth.
class TransactionHistoryScreen extends ConsumerStatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  ConsumerState<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState
    extends ConsumerState<TransactionHistoryScreen> {
  String _query = '';
  TradeStatus? _filter;
  HistoryRange _range = HistoryRange.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tradeHistoryProvider.notifier).load();
    });
  }

  List<Trade> _apply(List<Trade> trades, DateTime now) {
    var rows = trades;
    if (_filter != null) {
      rows = rows.where((t) => t.status == _filter).toList();
    }
    if (_range != HistoryRange.all) {
      rows = rows.where((t) => _range.includes(t.createdAt, now)).toList();
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      rows = rows
          .where((t) =>
              t.reference.toLowerCase().contains(q) ||
              t.beneficiaryName.toLowerCase().contains(q))
          .toList();
    }
    return rows;
  }

  /// Label for a status. The wording lives in the dictionaries (en / sw), so a
  /// language switch relabels the whole list.
  String _statusLabel(TradeStatus status) => ref.tr(status.labelKey);

  Color _statusColor(TradeStatus status) => switch (status) {
        TradeStatus.completed => AppColors.emerald,
        TradeStatus.failed => AppColors.danger,
        TradeStatus.expired => AppColors.warning,
        TradeStatus.cancelled => AppColors.textSecondary,
        _ => AppColors.warning,
      };

  /// F4.1 — asks the server for a CSV export link. The app never builds the
  /// file itself; it hands over the link the server issued.
  Future<void> _export() async {
    final ticket = await ref.read(tradeExportProvider.notifier).request();
    if (!mounted) return;
    if (ticket == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ref.tr('ledger.export_failed'))),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => _ExportSheet(ticket: ticket),
    );
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(tradeHistoryProvider);
    final rows = _apply(history.trades, DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('ledger.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.insights_outlined, size: 20),
            tooltip: ref.tr('ledger.analytics'),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.analytics),
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined, size: 20),
            tooltip: ref.tr('ledger.export'),
            onPressed: () {
              if (!ref.read(tradeExportProvider).busy) _export();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: ref.tr('ledger.refresh'),
            onPressed: () => ref.read(tradeHistoryProvider.notifier).load(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SearchField(
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 12),
                  _FilterChips(
                    selected: _filter,
                    onSelected: (s) => setState(() => _filter = s),
                  ),
                  const SizedBox(height: 8),
                  _RangeChips(
                    selected: _range,
                    onSelected: (r) => setState(() => _range = r),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _buildBody(history, rows),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(TradeHistoryState history, List<Trade> rows) {
    if (history.loading && history.trades.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (history.notConnected && history.trades.isEmpty) {
      return Center(
        child: Text(
          ref.tr('ledger.not_connected'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          ref.tr('ledger.empty'),
          style: const TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _TradeTile(
        trade: rows[i],
        statusLabel: _statusLabel(rows[i].status),
        statusColor: _statusColor(rows[i].status),
      ),
    );
  }
}

class _SearchField extends ConsumerWidget {
  const _SearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: ref.tr('ledger.search_hint'),
        hintStyle: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}

class _FilterChips extends ConsumerWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final TradeStatus? selected;
  final ValueChanged<TradeStatus?> onSelected;

  static const List<TradeStatus?> _options = [
    null,
    TradeStatus.completed,
    TradeStatus.escrowed,
    TradeStatus.failed,
  ];

  String _label(WidgetRef ref, TradeStatus? s) => switch (s) {
        null => ref.tr('ledger.filter.all'),
        TradeStatus.escrowed => ref.tr('ledger.filter.in_progress'),
        _ => ref.tr(s.labelKey),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in _options)
          ChoiceChip(
            label: Text(
              _label(ref, option),
              style: const TextStyle(fontSize: 13),
            ),
            selected: selected == option,
            selectedColor: AppColors.emerald.withOpacity(0.15),
            onSelected: (_) => onSelected(option),
          ),
      ],
    );
  }
}

class _RangeChips extends ConsumerWidget {
  const _RangeChips({required this.selected, required this.onSelected});

  final HistoryRange selected;
  final ValueChanged<HistoryRange> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in HistoryRange.values)
          ChoiceChip(
            label: Text(
              ref.tr(option.labelKey),
              style: const TextStyle(fontSize: 13),
            ),
            selected: selected == option,
            selectedColor: AppColors.navy.withOpacity(0.12),
            onSelected: (_) => onSelected(option),
          ),
      ],
    );
  }
}

/// The export link the server issued. Copying it is all the app does: the file
/// itself is built and served on the server.
class _ExportSheet extends ConsumerWidget {
  const _ExportSheet({required this.ticket});

  final ExportTicket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ref.tr('ledger.export_ready'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.navy,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              ticket.downloadUrl,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: AppColors.navy),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(
                    ClipboardData(text: ticket.downloadUrl),
                  );
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  messenger.showSnackBar(
                    SnackBar(content: Text(ref.tr('ledger.export_copied'))),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(ref.tr('ledger.export_copy')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TradeTile extends StatelessWidget {
  const _TradeTile({
    required this.trade,
    required this.statusLabel,
    required this.statusColor,
  });

  final Trade trade;
  final String statusLabel;
  final Color statusColor;

  String get _date => DateFormatX.day(trade.createdAt);

  @override
  Widget build(BuildContext context) {
    final send = MoneyFormat.format(
        trade.sendAmountMinor, trade.sendCurrency.decimals);
    final receive = MoneyFormat.format(
        trade.receiveAmountMinor, trade.receiveCurrency.decimals);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pushNamed(context, '/tracker',
            arguments: {'tradeId': trade.id}),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${trade.sendCurrency.code} $send → '
                      '${trade.receiveCurrency.code} $receive',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${trade.reference} · ${trade.beneficiaryName}',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _date,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}