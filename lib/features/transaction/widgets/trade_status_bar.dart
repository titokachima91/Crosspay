import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/models/trade_model.dart';

/// Visual progress bar showing the trade's current escrow stage.
class TradeStatusBar extends StatelessWidget {
  const TradeStatusBar({super.key, required this.status});

  final TradeStatus status;

  static const List<TradeStatus> _stages = [
    TradeStatus.pendingDeposit,
    TradeStatus.escrowed,
    TradeStatus.matching,
    TradeStatus.matched,
    TradeStatus.disbursing,
    TradeStatus.completed,
  ];

  static const Map<TradeStatus, String> _labels = {
    TradeStatus.pendingDeposit: 'Waiting for payment',
    TradeStatus.escrowed: 'Verifying payment',
    TradeStatus.matching: 'Finding payout route',
    TradeStatus.matched: 'Almost there',
    TradeStatus.disbursing: 'Paying out',
    TradeStatus.completed: 'Done',
  };

  int _currentIndex(TradeStatus status) =>
      _stages.indexWhere((s) => s == status);

  @override
  Widget build(BuildContext context) {
    final current = _currentIndex(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(_stages.length, (index) {
            final stage = _stages[index];
            final active = index <= current;
            return _StageDot(
              active: active,
              label: _labels[stage] ?? stage.name,
              isCurrent: index == current,
            );
          }),
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(_stages.length - 1, (index) {
            return Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: index < current
                    ? AppColors.emerald
                    : AppColors.border,
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _StageDot extends StatelessWidget {
  const _StageDot({
    required this.active,
    required this.label,
    required this.isCurrent,
  });

  final bool active;
  final String label;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: active ? AppColors.emerald : AppColors.border,
            shape: BoxShape.circle,
            border: isCurrent
                ? Border.all(color: AppColors.navy, width: 2)
                : null,
          ),
          child: active
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: active ? AppColors.textPrimary : AppColors.textSecondary,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}