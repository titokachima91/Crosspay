import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';

/// All dictionaries, loaded once in main() and injected there.
final translationsProvider = Provider<Map<String, AppLocalizations>>(
  (ref) => throw UnimplementedError('translationsProvider must be overridden'),
);

/// The language the user has selected: 'en' or 'sw'.
class LocaleCodeNotifier extends Notifier<String> {
  @override
  String build() => 'en';

  void setLanguage(String code) {
    if (AppLocalizations.supportedCodes.contains(code)) {
      state = code;
    }
  }
}

final localeCodeProvider =
    NotifierProvider<LocaleCodeNotifier, String>(LocaleCodeNotifier.new);

/// The active dictionary. Screens rebuild automatically when the language changes.
final localizationProvider = Provider<AppLocalizations>((ref) {
  final code = ref.watch(localeCodeProvider);
  return ref.watch(translationsProvider)[code]!;
});

/// Shortcuts for screens: ref.tr('nav.home')
extension TranslateX on WidgetRef {
  String tr(String key, {Map<String, String> params = const {}}) {
    return watch(localizationProvider).t(key, params: params);
  }

  /// Returns null when no translation exists for [key].
  String? trMaybe(String key, {Map<String, String> params = const {}}) {
    final l10n = watch(localizationProvider);
    return l10n.has(key) ? l10n.t(key, params: params) : null;
  }

  /// Message for a failure: a specific one when the app has a translation for
  /// the server's error code (error.code.<code>), otherwise the general
  /// message for [key].
  String trError({required String key, String? code}) {
    final specific = (code == null || code.isEmpty)
        ? null
        : trMaybe('error.code.${code.toLowerCase()}');
    return specific ?? tr(key);
  }
}
