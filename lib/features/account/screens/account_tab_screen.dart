import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F4.1 / F5.1 / F5.2 / F5.3 — Account tab: the entry point to Profile,
/// Recipients, History, Spending, Security and Language. Every tile leads to a
/// real screen; none of them shows invented data.
class AccountTabScreen extends ConsumerWidget {
  const AccountTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            ref.tr('account.title'),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 16),
          _Tile(
            icon: Icons.person_outline,
            title: ref.tr('account.profile'),
            subtitle: ref.tr('account.profile_sub'),
            route: AppRoutes.profile,
          ),
          _Tile(
            icon: Icons.people_outline,
            title: ref.tr('account.recipients'),
            subtitle: ref.tr('account.recipients_sub'),
            route: AppRoutes.recipients,
          ),
          _Tile(
            icon: Icons.history,
            title: ref.tr('account.history'),
            subtitle: ref.tr('account.history_sub'),
            route: AppRoutes.history,
          ),
          _Tile(
            icon: Icons.insights_outlined,
            title: ref.tr('account.analytics'),
            subtitle: ref.tr('account.analytics_sub'),
            route: AppRoutes.analytics,
          ),
          _Tile(
            icon: Icons.lock_outline,
            title: ref.tr('account.security'),
            subtitle: ref.tr('account.security_sub'),
            route: AppRoutes.security,
          ),
          _Tile(
            icon: Icons.language,
            title: ref.tr('account.language'),
            subtitle: ref.tr('account.language_sub'),
            route: AppRoutes.language,
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pushNamed(context, route),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.navy),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}