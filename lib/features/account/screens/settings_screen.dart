import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/providers/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLanguage = ref.watch(localeCodeProvider);
    final currentThemeMode = ref.watch(themeModeProvider);
    final codes = AppLocalizations.supportedCodes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        foregroundColor: AppColors.navy,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('Language'),
            const SizedBox(height: 8),
            ...codes.map((code) => _buildLanguageItem(
              code,
              context,
              ref,
              currentLanguage,
            )),
            const SizedBox(height: 24),
            _buildSectionTitle('Appearance'),
            const SizedBox(height: 8),
            ...AppThemeMode.values.map((mode) => _buildThemeItem(
              mode,
              context,
              ref,
              currentThemeMode,
            )),
            const SizedBox(height: 24),
            _buildSectionTitle('Security'),
            const SizedBox(height: 8),
            _buildSecuritySection(ref),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Expanded(
            child: Divider(height: 1, color: AppColors.border),
          ),
          SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Expanded(
            child: Divider(height: 1, color: AppColors.border),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageItem(
    String code,
    BuildContext context,
    WidgetRef ref,
    String currentLang,
  ) {
    final selected = code == currentLang;
    return InkWell(
      onTap: () => ref.read(localeCodeProvider.notifier).setLanguage(code),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? AppColors.emerald : AppColors.border,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? AppColors.emerald : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _languageName(code),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check,
                color: AppColors.emerald,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeItem(
    AppThemeMode mode,
    BuildContext context,
    WidgetRef ref,
    AppThemeMode currentMode,
  ) {
    final selected = mode == currentMode;
    return InkWell(
      onTap: () => ref.read(themeModeProvider.notifier).setThemeMode(mode),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? AppColors.emerald : Theme.of(context).colorScheme.outline,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? AppColors.emerald.withOpacity(0.08)
              : Theme.of(context).colorScheme.surface,
        ),
        child: Row(
          children: [
            Icon(
              switch (mode) {
                AppThemeMode.light => Icons.wb_sunny,
                AppThemeMode.dark => Icons.nights_stay,
                AppThemeMode.system => Icons.phone_android,
              },
              size: 20,
              color: selected ? AppColors.emerald : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                mode.displayName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check,
                color: AppColors.emerald,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecuritySection(WidgetRef ref) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.lock, color: AppColors.navy),
          title: const Text('App Lock'),
          subtitle: const Text('Require PIN to open app'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
          onTap: () {},
        ),
        const Divider(height: 24),
        ListTile(
          leading: const Icon(Icons.fingerprint, color: AppColors.navy),
          title: const Text('Biometric Unlock'),
          subtitle: const Text('Use fingerprint or Face ID'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
          onTap: () {},
        ),
      ],
    );
  }
}

extension AppThemeModeDisplay on AppThemeMode {
  String get displayName {
    switch (this) {
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
      case AppThemeMode.system:
        return 'System';
    }
  }
}
