import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// EN | SW toggle. The options come from the supported languages list.
class LanguageSwitcher extends ConsumerWidget {
  const LanguageSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(localeCodeProvider);

    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
      segments: [
        for (final code in AppLocalizations.supportedCodes)
          ButtonSegment<String>(value: code, label: Text(code.toUpperCase())),
      ],
      selected: {selected},
      onSelectionChanged: (selection) =>
          ref.read(localeCodeProvider.notifier).setLanguage(selection.first),
    );
  }
}
