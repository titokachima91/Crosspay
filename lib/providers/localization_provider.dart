import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';

/// All dictionaries, loaded once in main() and injected there.
final translationsProvider = Provider<Map<String, AppLocalizations>>(
  (ref) => throw UnimplementedError('translationsProvider must be overridden'),
);

/// The language the user has selected: 'en' or 'sw'. [initial] is what main()
/// read back from the device (F5.3), so the app reopens in the same language.
class LocaleCodeNotifier extends Notifier<String> {
  LocaleCodeNotifier({String initial = 'en'}) : _initial = initial;

  final String _initial;

  @override
  String build() => _initial;

  /// Switches the language and remembers the choice on this device. A device
  /// that cannot store it still switches for this run.
  Future<void> setLanguage(String code) async {
    if (!AppLocalizations.supportedCodes.contains(code)) return;
    state = code;
    try {
      await ref.read(languageStoreProvider).write(code);
    } catch (_) {
      // Nothing else to do: the choice lasts for this session only.
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
