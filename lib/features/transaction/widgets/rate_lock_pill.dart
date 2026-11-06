import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';

/// "Rate locked: 04:58", or "Rate expired". Hidden when there is no quote.
class RateLockPill extends ConsumerWidget {
  const RateLockPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(quoteProvider);
    final running = state.status == QuoteStatus.ready;
    final expired = state.status == QuoteStatus.expired;
    if (state.quote == null || (!running && !expired)) {
      return const SizedBox.shrink();
    }

    final color = expired ? AppColors.danger : AppColors.navy;
    final text = expired
        ? ref.tr('route.rate_expired')
        : ref.tr('route.rate_locked', params: {'time': state.remainingLabel});

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
