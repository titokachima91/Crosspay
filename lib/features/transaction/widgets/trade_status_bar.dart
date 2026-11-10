import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// Visual progress bar showing the trade's current escrow stage.
///
/// Every stage gets an equal share of the width so the labels can wrap on a
/// narrow phone instead of pushing the row past the screen edge.
class TradeStatusBar extends ConsumerWidget {
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

  int _currentIndex(TradeStatus status) =>
      _stages.indexWhere((s) => s == status);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = _currentIndex(status);
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = constraints.maxWidth / _stages.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _stages.length; i++)
                  Expanded(
                    child: _StageDot(
                      active: i <= current,
                      label: ref.tr(_stages[i].labelKey),
                      isCurrent: i == current,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: columnWidth / 2),
              child: Row(
                children: [
                  for (var i = 0; i < _stages.length - 1; i++)
                    Expanded(
                      child: Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: i < current
                            ? AppColors.emerald
                            : scheme.outlineVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
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
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: active ? AppColors.emerald : scheme.outlineVariant,
            shape: BoxShape.circle,
            border:
                isCurrent ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: active
              ? Icon(Icons.check, size: 12, color: scheme.onSecondary)
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: active ? scheme.onSurface : scheme.onSurfaceVariant,
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
