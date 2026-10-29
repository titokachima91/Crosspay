import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class AppLocalizations {
  AppLocalizations(this.languageCode, this._strings);

  final String languageCode;
  final Map<String, String> _strings;

  static const List<String> supportedCodes = ['en', 'sw'];

  static Future<AppLocalizations> load(String code) async {
    final raw = await rootBundle.loadString('lib/core/localization/$code.json');
    final decoded = json.decode(raw) as Map<String, dynamic>;
    return AppLocalizations(
      code,
      decoded.map((key, value) => MapEntry(key, value.toString())),
    );
  }

  static Future<Map<String, AppLocalizations>> loadAll() async {
    final result = <String, AppLocalizations>{};
    for (final code in supportedCodes) {
      result[code] = await load(code);
    }
    return result;
  }

  /// Returns the translation for [key]. A missing key shows the key itself,
  /// so gaps are easy to spot on screen.
  String t(String key, {Map<String, String> params = const {}}) {
    var value = _strings[key] ?? key;
    params.forEach((name, replacement) {
      value = value.replaceAll('{$name}', replacement);
    });
    return value;
  }
}
