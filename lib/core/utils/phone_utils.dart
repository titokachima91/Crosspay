import 'package:crosspay_app/models/app_config_model.dart';

/// Pure phone-number helpers. All rules (lengths, carrier patterns, calling
/// codes) come from the server config; nothing about any country is here.
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

  /// "1234567" becomes "123 456 7".
  static String groupDigits(String digits) {
    final parts = <String>[];
    for (var i = 0; i < digits.length; i += 3) {
      final end = i + 3 < digits.length ? i + 3 : digits.length;
      parts.add(digits.substring(i, end));
    }
    return parts.join(' ');
  }

  /// Display form of an international number, e.g. "+<code> 712 345 678".
  /// The longest matching calling code wins. If none matches, the number is
  /// returned unchanged.
  static String formatInternational(String phone, List<Country> countries) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');

    Country? match;
    for (final c in countries) {
      if (!digits.startsWith(c.dialCode)) continue;
      if (match == null || c.dialCode.length > match.dialCode.length) {
        match = c;
      }
    }
    if (match == null) return phone;

    final national = digits.substring(match.dialCode.length);
    return '+${match.dialCode} ${groupDigits(national)}';
  }

  /// "+255712345678" with calling code 255 becomes "712345678". The digits
  /// are returned unchanged when the number does not start with the code.
  static String nationalFromInternational(String phone, Country country) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.startsWith(country.dialCode)
        ? digits.substring(country.dialCode.length)
        : digits;
  }

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
