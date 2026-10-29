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

/// Shortcut for screens: ref.tr('nav.home')
extension TranslateX on WidgetRef {
  String tr(String key, {Map<String, String> params = const {}}) {
    return watch(localizationProvider).t(key, params: params);
  }
}
