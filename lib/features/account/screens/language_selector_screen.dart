import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// F3.7.2 Language selector — reuses the existing localeCodeProvider.
/// Only languages the app actually ships (AppLocalizations.supportedCodes)
/// are offered: no fake entries, choice remembered on this device.
class LanguageSelectorScreen extends ConsumerWidget {
  const LanguageSelectorScreen({super.key});

  static String _name(String code) => switch (code) {
        'en' => 'English',
        'sw' => 'Kiswahili',
        _ => code.toUpperCase(),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeCodeProvider);
    final codes = AppLocalizations.supportedCodes;

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
              itemCount: codes.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final code = codes[i];
                final selected = code == current;
                return Material(
                  color: selected
                      ? AppColors.emerald.withOpacity(0.08)
                      : AppColors.surface,
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
