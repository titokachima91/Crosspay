/// Money display and input helpers. Amounts are always whole numbers in the
/// currency's smallest unit; `decimals` (from the server) says how many digits
/// follow the decimal point on screen.
class MoneyFormat {
  MoneyFormat._();

  /// Technical safety limit so amounts stay exactly representable on every
  /// platform, including the web.
  static const int maxDigits = 15;

  static int _pow10(int exponent) {
    var result = 1;
    for (var i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }

  /// "5000000" becomes "5,000,000".
  static String group(String digits) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// 25188917 with 2 decimals becomes "251,889.17".
  static String format(int minor, int decimals) {
    final sign = minor < 0 ? '-' : '';
    final abs = minor.abs();
    if (decimals <= 0) return '$sign${group(abs.toString())}';

    final divisor = _pow10(decimals);
    final whole = abs ~/ divisor;
    final fraction = (abs % divisor).toString().padLeft(decimals, '0');
    return '$sign${group(whole.toString())}.$fraction';
  }

  /// Reads what a person typed ("5,000,000" or "251,889.17") into whole
  /// smallest units. Returns null for empty or invalid text.
  static int? parse(String text, int decimals) {
    final places = decimals < 0 ? 0 : decimals;
    final cleaned = text.replaceAll(',', '').replaceAll(' ', '');
    final match = RegExp(r'^(\d*)(?:\.(\d*))?$').firstMatch(cleaned);
    if (match == null) return null;

    final wholeText = match.group(1) ?? '';
    final fractionText = match.group(2) ?? '';
    if (wholeText.isEmpty && fractionText.isEmpty) return null;
    if (fractionText.length > places) return null;
    if (wholeText.length + places > maxDigits) return null;

    final whole = int.parse(wholeText.isEmpty ? '0' : wholeText);
    final fraction =
        places == 0 ? 0 : int.parse(fractionText.padRight(places, '0'));
    return whole * _pow10(places) + fraction;
  }

  /// Exchange rate for display: "19.85" or "0.0504".
  static String rate(double value) =>
      value >= 1 ? value.toStringAsFixed(2) : value.toStringAsFixed(4);
}
