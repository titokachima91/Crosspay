import 'dart:math' as math;
import 'package:flutter/services.dart';

/// Phone field formatter: digits only, no leading zero, capped at
/// [maxDigits], shown in groups of three (e.g. "712 345 678").
class NationalNumberFormatter extends TextInputFormatter {
  NationalNumberFormatter({required this.maxDigits});

  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final rawCursor = newValue.selection.isValid
        ? math.min(math.max(newValue.selection.extentOffset, 0), raw.length)
        : raw.length;

    final buffer = StringBuffer();
    var digitsBeforeCursor = 0;
    for (var i = 0; i < raw.length; i++) {
      final unit = raw.codeUnitAt(i);
      if (unit >= 48 && unit <= 57) {
        buffer.write(raw[i]);
        if (i < rawCursor) digitsBeforeCursor++;
      }
    }

    var digits = buffer.toString();
    final stripped = digits.replaceFirst(RegExp(r'^0+'), '');
    digitsBeforeCursor =
        math.max(0, digitsBeforeCursor - (digits.length - stripped.length));
    digits = stripped;

    if (maxDigits > 0 && digits.length > maxDigits) {
      digits = digits.substring(0, maxDigits);
    }
    digitsBeforeCursor = math.min(digitsBeforeCursor, digits.length);

    final spacesBeforeCursor =
        digitsBeforeCursor > 0 ? (digitsBeforeCursor - 1) ~/ 3 : 0;

    return TextEditingValue(
      text: _group(digits),
      selection: TextSelection.collapsed(
        offset: digitsBeforeCursor + spacesBeforeCursor,
      ),
    );
  }

  static String _group(String digits) {
    final parts = <String>[];
    for (var i = 0; i < digits.length; i += 3) {
      parts.add(digits.substring(i, math.min(i + 3, digits.length)));
    }
    return parts.join(' ');
  }
}
