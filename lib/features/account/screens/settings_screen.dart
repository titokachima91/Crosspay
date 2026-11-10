import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/theme_provider.dart';

/// F5.3 — one place for language, appearance and the way into the security
/// screen. Every visible value comes from a provider or a shipped dictionary;
/// nothing is invented here.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLanguage = ref.watch(localeCodeProvider);
    final currentThemeMode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.tr('settings.title')),
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _SectionTitle(ref.tr('settings.language')),
                const SizedBox(height: 8),
                ...AppLocalizations.supportedCodes.map(
                  (code) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _LanguageTile(
                      code: code,
                      selected: code == currentLanguage,
                      onTap: () => ref
                          .read(localeCodeProvider.notifier)
                          .setLanguage(code),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _SectionTitle(ref.tr('settings.appearance')),
                const SizedBox(height: 8),
                ...AppThemeMode.values.map(
                  (mode) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ThemeTile(
                      mode: mode,
                      label: ref.tr(mode.labelKey),
                      selected: mode == currentThemeMode,
                      onTap: () => ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(mode),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _SectionTitle(ref.tr('settings.security')),
                const SizedBox(height: 8),
                _SettingsTile(
                  icon: Icons.lock_outline,
                  title: ref.tr('settings.app_lock'),
                  subtitle: ref.tr('settings.app_lock_sub'),
                  onTap: () => Navigator.pushNamed(context, AppRoutes.security),
                ),
                const SizedBox(height: 24),
                _SectionTitle(ref.tr('settings.support')),
                const SizedBox(height: 8),
                _SettingsTile(
                  icon: Icons.support_agent,
                  title: ref.tr('settings.support_title'),
                  subtitle: ref.tr('settings.support_sub'),
                  onTap: () => Navigator.pushNamed(context, AppRoutes.support),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
      ],
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.code,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ChoiceTile(
      icon: selected ? Icons.radio_button_checked : Icons.radio_button_off,
      label: AppLocalizations.displayName(code),
      trailing: code.toUpperCase(),
      selected: selected,
      onTap: onTap,
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ChoiceTile(
      icon: mode.icon,
      label: label,
      selected: selected,
      onTap: onTap,
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? AppColors.emerald.withOpacity(0.08) : scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.emerald : scheme.outline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? AppColors.emerald : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color:
                        selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing!,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (selected) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.check,
                  color: AppColors.emerald,
                  size: 20,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outline),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension AppThemeModeDisplay on AppThemeMode {
  String get labelKey => switch (this) {
        AppThemeMode.light => 'settings.theme_light',
        AppThemeMode.dark => 'settings.theme_dark',
        AppThemeMode.system => 'settings.theme_system',
      };

  IconData get icon => switch (this) {
        AppThemeMode.light => Icons.wb_sunny,
        AppThemeMode.dark => Icons.nights_stay,
        AppThemeMode.system => Icons.phone_android,
      };
}
