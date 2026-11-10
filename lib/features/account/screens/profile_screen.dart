import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/utils/money_format.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/profile_provider.dart';

/// F5.1 — Profile with the daily limit bar. Everything shown is the server's
/// `/me` answer; the bar is drawn from the limit it sends, never from a local
/// total. While `/me` is unreachable the screen says so plainly.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(profileProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(profileProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('profile.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: ref.tr('common.retry'),
            onPressed: () => ref.read(profileProvider.notifier).load(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _body(state),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ProfileState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.status == ProfileStatus.loading && state.profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProfileStatus.error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ref.tr(state.errorKey ?? 'error.unknown'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => ref.read(profileProvider.notifier).load(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(ref.tr('common.retry')),
            ),
          ],
        ),
      );
    }

    final profile = state.profile;
    if (profile == null) {
      return Center(
        child: Text(
          ref.tr('profile.unavailable'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return ListView(
      children: [
        _Header(profile: profile),
        const SizedBox(height: 16),
        _Details(profile: profile),
        const SizedBox(height: 16),
        _LimitBar(profile: profile),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final initial = profile.displayName.trim().isEmpty
        ? '?'
        : profile.displayName.trim().characters.first.toUpperCase();

    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary,
            shape: BoxShape.circle,
          ),
          child: Text(
            initial,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimary,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.displayName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                profile.phone,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Details extends ConsumerWidget {
  const _Details({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          _row(
            ref.tr('profile.account_type'),
            ref.tr('profile.type.${profile.accountType.name}'),
            context: context,
          ),
          if (profile.hub != null) ...[
            const Divider(height: 20),
            _row(ref.tr('profile.hub'), profile.hub!.name, context: context),
          ],
          const Divider(height: 20),
          _row(
            ref.tr('profile.kyc'),
            ref.tr('profile.kyc.${profile.kycStatus.name}'),
            valueColor: profile.isVerified ? AppColors.emerald : null,
            context: context,
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    String value, {
    Color? valueColor,
    required BuildContext context,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: valueColor ?? scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _LimitBar extends ConsumerWidget {
  const _LimitBar({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final decimals = profile.limitCurrency.decimals;
    final used = MoneyFormat.format(profile.dailyUsedMinor, decimals);
    final limit = MoneyFormat.format(profile.dailyLimitMinor, decimals);
    final remaining = MoneyFormat.format(profile.dailyRemainingMinor, decimals);
    final code = profile.limitCurrency.code;

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
            ref.tr('profile.limit.title').toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: profile.dailyUsedFraction,
              minHeight: 10,
              backgroundColor: scheme.outlineVariant,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.emerald,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            ref.tr('profile.limit.used', params: {
              'used': '$code $used',
              'limit': '$code $limit',
            }),
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            ref.tr('profile.limit.remaining', params: {
              'amount': '$code $remaining',
            }),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}