import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/localization/app_localizations.dart';
import 'package:crosspay_app/core/storage/language_store.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

// Test inputs and stand-ins only. Not app data or app code.
class _MemoryLanguageStore implements LanguageStore {
  _MemoryLanguageStore([this.value]);

  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String code) async {
    writes++;
    value = code;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, AppLocalizations> translations;

  setUpAll(() async {
    translations = await AppLocalizations.loadAll();
  });

  ProviderContainer containerWith(_MemoryLanguageStore store, {String initial = 'en'}) =>
      ProviderContainer(overrides: [
        translationsProvider.overrideWithValue(translations),
        languageStoreProvider.overrideWithValue(store),
        localeCodeProvider.overrideWith(
          () => LocaleCodeNotifier(initial: initial),
        ),
      ]);

  test('a stored language is what the app opens in', () {
    final container = containerWith(_MemoryLanguageStore('sw'), initial: 'sw');
    addTearDown(container.dispose);

    expect(container.read(localeCodeProvider), 'sw');
    expect(container.read(localizationProvider).languageCode, 'sw');
  });

  test('choosing a language remembers it on the device', () async {
    final store = _MemoryLanguageStore();
    final container = containerWith(store);
    addTearDown(container.dispose);

    await container.read(localeCodeProvider.notifier).setLanguage('sw');

    expect(container.read(localeCodeProvider), 'sw');
    expect(store.value, 'sw');
    expect(store.writes, 1);
  });

  test('a language the app does not ship is ignored', () async {
    final store = _MemoryLanguageStore();
    final container = containerWith(store);
    addTearDown(container.dispose);

    await container.read(localeCodeProvider.notifier).setLanguage('fr');

    expect(container.read(localeCodeProvider), 'en');
    expect(store.writes, 0);
  });
}