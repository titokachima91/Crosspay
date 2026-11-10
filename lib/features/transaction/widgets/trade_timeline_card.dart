import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/date_format.dart';
import 'package:crosspay_app/models/trade_event_model.dart';
import 'package:crosspay_app/models/trade_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_timeline_provider.dart';

/// F4.1 — the trade's status change timeline. Everything shown here came from
/// `GET /trades/{id}/history`; until that endpoint exists the card says so
/// plainly instead of inventing steps (product rules 2, 6 and 11).
class _EventRow extends ConsumerWidget {
  const _EventRow({required this.event, required this.isLast});

  final TradeEvent event;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 4),
            decoration: const BoxDecoration(
              color: AppColors.emerald,
              shape: BoxShape.circle,
            ),
          ),
          if (!isLast)
            Expanded(
              child: Container(width: 2, color: scheme.outlineVariant),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ref.tr(event.status.labelKey),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DateFormatX.dayTime(event.at),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TradeTimelineCard extends ConsumerStatefulWidget {
  const TradeTimelineCard({super.key, required this.tradeId});

  final String tradeId;

  @override
  ConsumerState<TradeTimelineCard> createState() => _TradeTimelineCardState();
}

class _TradeTimelineCardState extends ConsumerState<TradeTimelineCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(tradeTimelineProvider.notifier).load(widget.tradeId);
      }
    });
  }

  @override
  void didUpdateWidget(covariant TradeTimelineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tradeId != widget.tradeId) {
      ref.read(tradeTimelineProvider.notifier).load(widget.tradeId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timeline = ref.watch(tradeTimelineProvider);

    final Widget body;
    switch (timeline.status) {
      case TimelineStatus.idle:
      case TimelineStatus.loading:
        body = const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      case TimelineStatus.unavailable:
        body = _note(ref.tr('history.timeline.unavailable'));
      case TimelineStatus.error:
        body = _note(ref.tr(timeline.errorKey ?? 'error.unknown'));
      case TimelineStatus.ready:
        body = timeline.events.isEmpty
            ? _note(ref.tr('history.timeline.empty'))
            : Column(
                children: [
                  for (var i = 0; i < timeline.events.length; i++)
                    _EventRow(
                      event: timeline.events[i],
                      isLast: i == timeline.events.length - 1,
                    ),
                ],
              );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tr('history.timeline.title').toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurface),
          ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }

  Widget _note(String text) => Text(
        text,
        style: TextStyle(
            fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}
