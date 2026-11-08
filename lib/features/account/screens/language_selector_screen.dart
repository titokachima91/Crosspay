import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F5.3 Language selector — reuses the existing localeCodeProvider.
/// Only languages the app actually ships (AppLocalizations.supportedCodes)
/// are offered: no fake entries, choice remembered on this device.
class LanguageSelectorScreen extends ConsumerWidget {
  const LanguageSelectorScreen({super.key});

  static String _name(String code) => switch (code) {
        'en' => 'English',
        'sw' => 'Kiswahili',
        _ => code.toUpperCase(),
      };

  static String _themeName(AppThemeMode mode) => switch (mode) {
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
        AppThemeMode.system => 'System',
      };

  static IconData _themeIcon(AppThemeMode mode) => switch (mode) {
        AppThemeMode.light => Icons.wb_sunny,
        AppThemeMode.dark => Icons.nights_stay,
        AppThemeMode.system => Icons.phone_android,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeCodeProvider);
    final themeMode = ref.watch(themeModeProvider);
    const codes = AppLocalizations.supportedCodes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Language'),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.navy,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: codes.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                if (i == codes.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Theme Mode',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...AppThemeMode.values.map((mode) {
                          final selected = mode == themeMode;
                          return Material(
                            color: selected
                                ? AppColors.emerald.withOpacity(0.08)
                                : Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () async {
                                await ref.read(themeStoreProvider).write(mode);
                                ref.read(themeModeProvider.notifier).state = mode;
                              },
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: selected
                                        ? AppColors.emerald
                                        : AppColors.border,
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      _themeIcon(mode),
                                      size: 20,
                                      color: selected
                                          ? AppColors.emerald
                                          : AppColors.textSecondary,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        _themeName(mode),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if (selected)
                                      const Icon(
                                        Icons.check,
                                        color: AppColors.emerald,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  );
                }
                final code = codes[i];
                final selected = code == current;
                return Material(
                  color: selected
                      ? AppColors.emerald.withOpacity(0.08)
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => ref
                        .read(localeCodeProvider.notifier)
                        .setLanguage(code),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color:
                              selected ? AppColors.emerald : AppColors.border,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 20,
                            color: selected
                                ? AppColors.emerald
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _name(code),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            code.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Theme mode provider — reads/writes to secure storage.
final themeModeProvider = StateNotifierProvider<AppThemeModeNotifier, AppThemeMode>(
  (ref) => AppThemeModeNotifier(ref.read(themeStoreProvider)),
);

class AppThemeModeNotifier extends StateNotifier<AppThemeMode> {
  final ThemeStore _store;

  AppThemeModeNotifier(this._store) : super(AppThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    try {
      final stored = await _store.read();
      if (stored != null) state = stored;
    } catch (_) {
      // Keep system default.
    }
  }

  @override
  Future<void> setState(AppThemeMode newState) async {
    await _store.write(newState);
    super.state = newState;
  }
}
