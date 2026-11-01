import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/profile_provider.dart';
import 'package:crosspay_app/widgets/status_badge.dart';

/// Name, verification badge and "Available today" (the remaining daily limit).
class HomeHeader extends ConsumerWidget {
  const HomeHeader({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(profileProvider);
    final profile = state.profile;

    if (profile == null) {
      if (state.status == ProfileStatus.error) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ref.tr(state.errorKey ?? 'error.unknown'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }

    final (label, tone) = switch (profile.kycStatus) {
      KycStatus.verified => (ref.tr('home.status_verified'), BadgeTone.success),
      KycStatus.pending => (ref.tr('home.status_pending'), BadgeTone.warning),
      KycStatus.rejected => (ref.tr('home.status_rejected'), BadgeTone.danger),
      KycStatus.notStarted =>
        (ref.tr('home.status_not_started'), BadgeTone.neutral),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              profile.accountType == AccountType.business
                  ? Icons.business
                  : Icons.person,
              color: AppColors.navy,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                profile.displayName,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(width: 8),
            StatusBadge(label: label, tone: tone),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          ref.tr('home.available_today', params: {
            'amount': MoneyFormat.format(
              profile.dailyRemainingMinor,
              profile.limitCurrency.decimals,
            ),
            'currency': profile.limitCurrency.code,
          }),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}
