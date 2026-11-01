import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/providers/beneficiaries_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/trade_provider.dart';

/// "Saved recipients": tap one to send to them. ("+ Add new" and "View all"
/// arrive with the recipients screen, F5.2.)
class SavedRecipientsRow extends ConsumerWidget {
  const SavedRecipientsRow({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(beneficiariesProvider);
    final selectedId = ref.watch(tradeProvider).beneficiary?.id;
    final theme = Theme.of(context);

    final Widget body;
    if (state.status == BeneficiariesStatus.error) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ref.tr(state.errorKey ?? 'error.unknown'),
            style: theme.textTheme.bodyMedium,
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(ref.tr('common.retry')),
          ),
        ],
      );
    } else if (state.items.isNotEmpty) {
      body = SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: state.items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final b = state.items[index];
            final selected = b.id == selectedId;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () =>
                  ref.read(tradeProvider.notifier).selectBeneficiary(b),
              child: SizedBox(
                width: 76,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: selected
                          ? AppColors.navy
                          : AppColors.navy.withOpacity(0.1),
                      child: Text(
                        _initials(b.name),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : AppColors.navy,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      b.name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } else if (state.status == BeneficiariesStatus.ready) {
      body = Text(
        ref.tr('home.no_recipients'),
        style: theme.textTheme.bodyMedium,
      );
    } else {
      body = const SizedBox(
        height: 40,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ref.tr('home.recipients_title').toUpperCase(),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 12),
        body,
      ],
    );
  }
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  final first = parts.first.substring(0, 1);
  final second = parts.length > 1 ? parts[1].substring(0, 1) : '';
  return (first + second).toUpperCase();
}
