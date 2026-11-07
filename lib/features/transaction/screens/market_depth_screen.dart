import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';
import 'package:crosspay_app/core/utils/date_format.dart';
import 'package:crosspay_app/models/market_depth_model.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/market_depth_provider.dart';

/// F4.2 — market depth and queue health (`GET /market/depth`). Every number is
/// the server's; while the endpoint does not exist the screen says so plainly.
class MarketDepthScreen extends ConsumerStatefulWidget {
  const MarketDepthScreen({super.key});

  @override
  ConsumerState<MarketDepthScreen> createState() => _MarketDepthScreenState();
}

class _MarketDepthScreenState extends ConsumerState<MarketDepthScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(marketDepthProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(marketDepthProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('market.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: ref.tr('market.refresh'),
            onPressed: () => ref.read(marketDepthProvider.notifier).load(),
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
                  Text(
                    ref.tr('market.subtitle'),
                    style: TextStyle(
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: _body(state)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(MarketDepthState state) {
    if (state.status == MarketDepthStatus.loading && state.corridors.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == MarketDepthStatus.unavailable) {
      return Center(
        child: Text(
          ref.tr('market.unavailable'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }
    if (state.status == MarketDepthStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref.tr(state.errorKey ?? 'error.unknown'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => ref.read(marketDepthProvider.notifier).load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        ),
      );
    }
    if (state.corridors.isEmpty) {
      return Center(
        child: Text(
          ref.tr('market.empty'),
          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
        ),
      );
    }
    return ListView(
      children: [
        for (final corridor in state.corridors) _CorridorCard(depth: corridor),
      ],
    );
  }
}

class _CorridorCard extends ConsumerWidget {
  const _CorridorCard({required this.depth});

  final CorridorDepth depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = depth.status;
    final dotColor = switch (status?.level) {
      CorridorLevel.healthy => AppColors.success,
      CorridorLevel.limited => AppColors.warning,
      CorridorLevel.down => AppColors.danger,
      null => Theme.of(context).colorScheme.outline,
    };

    String? statusLabel;
    if (status != null) {
      statusLabel = ref.trMaybe('corridor.status.${status.code}') ??
          ref.tr('corridor.level.${status.level.name}');
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${countryFlag(depth.from.countryCode)} ${depth.from.code}'
                  '  \u21C4  '
                  '${countryFlag(depth.to.countryCode)} ${depth.to.code}',
                  style: TextStyle(
                  ),
                ),
              ),
              if (statusLabel != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    statusLabel,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            ref.tr('market.queue', params: {'count': '${depth.queueDepth}'}),
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface),
          ),
          Text(
            ref.tr('market.settle', params: {
              'time': DateFormatX.duration(depth.estimatedSettleSeconds),
            }),
            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
          ),
        ],
      ),
    );
  }
}