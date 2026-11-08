import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/core/theme/theme_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// Professional settings screen with Language, Theme, and Security sections.
/// Organized into categories for a clean user experience.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeCodeNotifier = ref.read(localeCodeProvider.notifier);
    final currentLanguage = ref.watch(localeCodeProvider);
    final currentThemeMode = ref.watch(themeModeProvider);
    final codes = AppLocalizations.supportedCodes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.navy,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // === LANGUAGE SECTION ===
            _buildSectionTitle('Language'),
            const SizedBox(height: 8),
            _buildLanguageList(ref, localeCodeNotifier, codes),
            const SizedBox(height: 24),

            // === THEME SECTION ===
            _buildSectionTitle('Appearance'),
            const SizedBox(height: 8),
            _buildThemeModeList(ref, currentThemeMode),
            const SizedBox(height: 24),

            // === SECURITY SECTION ===
            _buildSectionTitle('Security'),
            const SizedBox(height: 8),
            _buildSecurityOptions(ref),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  /// Builds a section header with a subtle divider
  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, color: AppColors.border),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const Expanded(
            child: Divider(height: 1, color: AppColors.border),
          ),
        ],
      ),
    );
  }

  /// Builds the language selection list
  Widget _buildLanguageList(
    WidgetRef ref,
    StateLocator localeCodeNotifier,
    List<String> codes,
  ) {
    final currentLanguage = ref.watch(localeCodeProvider);

    return Column(
      children: codes.map((code) {
        final isSelected = code == currentLanguage.languageCode;
        return InkWell(
          onTap: () => localeCodeNotifier.setLanguage(code),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected ? AppColors.emerald : AppColors.border,
                width: isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 20,
                  color: isSelected ? AppColors.emerald : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppLocalizations._name(code),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                  ),
                ),
                if (isSelected)
                  const Icon(
                    Icons.check,
                    color: AppColors.emerald,
                    size: 20,
                  ),
              ],
            ),
          ),
        );
      }).toList(growable: false),
    );
  }

  /// Builds the theme mode selection list
  Widget _buildThemeModeList(
    WidgetRef ref,
    AppThemeMode currentThemeMode,
  ) {
    return Column(
      children: AppThemeMode.values.map((mode) {
        final isSelected = mode == currentThemeMode;
        return InkWell(
          onTap: () => ref.read(themeModeProvider.notifier).setThemeMode(mode),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected ? AppColors.emerald : Theme.of(context).colorScheme.outline,
                width: isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
              color: isSelected
                  ? AppColors.emerald.withOpacity(0.08)
                  : Theme.of(context).colorScheme.surface,
            ),
            child: Row(
              children: [
                Icon(
                  _themeIcon(mode),
                  size: 20,
                  color: isSelected ? AppColors.emerald : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _themeName(mode),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                  ),
                ),
                if (isSelected)
                  const Icon(
                    Icons.check,
                    color: AppColors.emerald,
                    size: 20,
                  ),
              ],
            ),
          ),
        );
      }).toList(growable: false),
    );
  }

  /// Builds security options
  Widget _buildSecurityOptions(WidgetRef ref) {
    return Column(
      children: [
        // PIN lock option
        ListTile(
          leading: const Icon(Icons.lock, color: AppColors.navy),
          title: const Text('App Lock'),
          subtitle: const Text('Require PIN to open app'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
          onTap: () {
            // Navigate to security settings
          },
        ),
        const Divider(height: 24),

        // Biometric option
        ListTile(
          leading: const Icon(Icons.fingerprint, color: AppColors.navy),
          title: const Text('Biometric Unlock'),
          subtitle: const Text('Use fingerprint or Face ID'),
          trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
          onTap: () {
            // Handle biometric
          },
        ),
      ],
    );
  }
}

/// Helper extension for theme mode naming
extension ThemeModeExtension on AppThemeMode {
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
