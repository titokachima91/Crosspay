import 'package:crosspay_app/models/app_config_model.dart';

/// Pure phone-number helpers. All rules (lengths, carrier patterns) come from
/// the server config; nothing about any country is written here.
class PhoneUtils {
  PhoneUtils._();

  /// Keeps digits only and removes leading zeros.
  static String normalizeNational(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    return digits.replaceFirst(RegExp(r'^0+'), '');
  }

  static bool isComplete(Country country, String input) =>
      normalizeNational(input).length == country.nationalNumberLength;

  /// International format sent to the server: +<calling code><number>.
  static String toInternational(Country country, String input) =>
      '+${country.dialCode}${normalizeNational(input)}';

  /// Suggests a carrier from the number's prefix. Returns null when nothing
  /// matches. A suggestion only: customers can keep their number when they
  /// switch networks.
  static Carrier? detectCarrier({
    required Country country,
    required String input,
    required List<Carrier> carriers,
  }) {
    final national = normalizeNational(input);
    if (national.isEmpty) return null;

    for (final carrier in carriers) {
      if (carrier.countryCode != country.code) continue;
      final RegExp pattern;
      try {
        pattern = RegExp(carrier.prefixPattern);
      } on FormatException {
        continue; // a broken pattern from the server must not crash the app
      }
      if (pattern.matchAsPrefix(national) != null) return carrier;
    }
    return null;
  }
}
