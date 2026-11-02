import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/features/transaction/widgets/fee_breakdown_card.dart';
import 'package:crosspay_app/features/transaction/widgets/route_option_card.dart';
import 'package:crosspay_app/models/quote_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/quote_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 2.2: choose a route while the rate is locked.
///
/// A new quote is requested every time the screen opens. When the lock ends
/// the screen says so and offers a new rate; it never re-prices silently.
class RouteSelectionScreen extends ConsumerStatefulWidget {
  const RouteSelectionScreen({super.key});

  @override
  ConsumerState<RouteSelectionScreen> createState() =>
      _RouteSelectionScreenState();
}

class _RouteSelectionScreenState extends ConsumerState<RouteSelectionScreen> {
  // Until the first request starts, show the spinner so an older quote from a
  // previous visit never flashes on screen.
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _requested = true;
      await ref.read(quoteProvider.notifier).requestQuote();
      if (mounted) setState(() {});
    });
  }

  Future<void> _getNewRate() => ref.read(quoteProvider.notifier).requestQuote();

  /// The available route with the shortest worst-case time (only worth
  /// marking when there is more than one to compare).
  RouteType? _fastest(Quote quote) {
    final available = quote.routes.where((r) => r.isAvailable).toList();
    if (available.length < 2) return null;
    available.sort(
      (a, b) => a.estimatedMaxSeconds.compareTo(b.estimatedMaxSeconds),
    );
    return available.first.route;
  }

  Widget _message(String text, {String? actionLabel, VoidCallback? onAction}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quoteProvider);
    final quote = state.quote;
    final expired = state.status == QuoteStatus.expired;
    final hasQuote =
        quote != null &&
        (state.status == QuoteStatus.ready || state.status == QuoteStatus.expired);

    final selectedRoute = state.selectedRoute;
    final selectedOption = (quote != null && selectedRoute != null)
        ? quote.forRoute(selectedRoute)
        : null;
    final canProceed = state.status == QuoteStatus.ready &&
        selectedOption != null &&
        selectedOption.isAvailable;

    final Widget body;
    if (!_requested || state.status == QuoteStatus.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (state.status == QuoteStatus.error) {
      body = _message(
        ref.trError(key: state.errorKey ?? 'error.unknown', code: state.errorCode),
        actionLabel: ref.tr('common.retry'),
        onAction: _getNewRate,
      );
    } else if (!hasQuote) {
      body = _message(ref.tr('route.no_amount'));
    } else {
      final fastest = _fastest(quote);
      body = ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        children: [
          Text(
            ref.tr('route.title'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
          ),
          const SizedBox(height: 16),
          IgnorePointer(
            ignoring: expired,
            child: Opacity(
              opacity: expired ? 0.5 : 1,
              child: Column(
                children: [
                  for (var i = 0; i < quote.routes.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    RouteOptionCard(
                      letter: String.fromCharCode(65 + i),
                      quote: quote,
                      option: quote.routes[i],
                      selected: quote.routes[i].route == selectedRoute,
                      isFastest: quote.routes[i].route == fastest,
                      onTap: () => ref
                          .read(quoteProvider.notifier)
                          .selectRoute(quote.routes[i].route),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (selectedOption != null && !expired) ...[
            const SizedBox(height: 16),
            FeeBreakdownCard(quote: quote, option: selectedOption),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          if (hasQuote)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: _LockPill(
                  expired: expired,
                  text: expired
                      ? ref.tr('route.rate_expired')
                      : ref.tr('route.rate_locked', params: {
                          'time': state.remainingLabel,
                        }),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Expanded(child: body),
                if (hasQuote)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: expired
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                ref.tr('route.expired_notice'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.danger),
                              ),
                              const SizedBox(height: 12),
                              CustomButton(
                                label: ref.tr('route.get_new_rate'),
                                onPressed: _getNewRate,
                              ),
                            ],
                          )
                        : CustomButton(
                            label: ref.tr('route.proceed'),
                            onPressed: canProceed
                                ? () => Navigator.of(context)
                                    .pushNamed(AppRoutes.recipient)
                                : null,
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LockPill extends StatelessWidget {
  const _LockPill({required this.text, required this.expired});

  final String text;
  final bool expired;

  @override
  Widget build(BuildContext context) {
    final color = expired ? AppColors.danger : AppColors.navy;
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
