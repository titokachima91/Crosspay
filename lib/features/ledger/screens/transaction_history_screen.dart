import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/trade_history_provider.dart';

/// Date windows offered above the list. [days] is null for "all time".
enum HistoryRange {
  all('All time', null),
  last7('Last 7 days', 7),
  last30('Last 30 days', 30),
  last90('Last 90 days', 90);

  const HistoryRange(this.label, this.days);

  final String label;
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

  String _statusLabel(TradeStatus status) => switch (status) {
        TradeStatus.pendingDeposit => 'Waiting for payment',
        TradeStatus.escrowed => 'Verifying payment',
        TradeStatus.matching => 'Finding payout route',
        TradeStatus.matched => 'Almost there',
        TradeStatus.disbursing => 'Paying out',
        TradeStatus.completed => 'Done',
        TradeStatus.expired => 'Rate expired',
        TradeStatus.refunded => 'Refunded',
        TradeStatus.failed => 'Failed',
        TradeStatus.cancelled => 'Cancelled',
      };

  Color _statusColor(TradeStatus status) => switch (status) {
        TradeStatus.completed => AppColors.emerald,
        TradeStatus.failed => AppColors.danger,
        TradeStatus.expired => AppColors.warning,
        TradeStatus.cancelled => AppColors.textSecondary,
        _ => AppColors.warning,
      };

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(tradeHistoryProvider);
    final rows = _apply(history.trades, DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh history',
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
      return const Center(
        child: Text(
          'Trade history is not connected yet.\nPlease try again later.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Center(
        child: Text(
          'No trades found.',
          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
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

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search by reference or recipient',
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

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onSelected});

  final TradeStatus? selected;
  final ValueChanged<TradeStatus?> onSelected;

  static const List<TradeStatus?> _options = [
    null,
    TradeStatus.completed,
    TradeStatus.escrowed,
    TradeStatus.failed,
  ];

  String _label(TradeStatus? s) => switch (s) {
        null => 'All',
        TradeStatus.completed => 'Done',
        TradeStatus.escrowed => 'In progress',
        TradeStatus.failed => 'Failed',
        _ => 'Other',
      };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in _options)
          ChoiceChip(
            label: Text(_label(option), style: const TextStyle(fontSize: 13)),
            selected: selected == option,
            selectedColor: AppColors.emerald.withOpacity(0.15),
            onSelected: (_) => onSelected(option),
          ),
      ],
    );
  }
}

class _RangeChips extends StatelessWidget {
  const _RangeChips({required this.selected, required this.onSelected});

  final HistoryRange selected;
  final ValueChanged<HistoryRange> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in HistoryRange.values)
          ChoiceChip(
            label: Text(option.label, style: const TextStyle(fontSize: 13)),
            selected: selected == option,
            selectedColor: AppColors.navy.withOpacity(0.12),
            onSelected: (_) => onSelected(option),
          ),
      ],
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

  String get _date {
    final d = trade.createdAt;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

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