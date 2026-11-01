import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:crosspay_app/core/utils/money_format.dart';

/// Amount field formatter: digits and one decimal point (only when the
/// currency has decimals), grouped in thousands as you type ("1,234.56").
class AmountInputFormatter extends TextInputFormatter {
  AmountInputFormatter({required this.decimals});

  final int decimals;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final rawCursor = newValue.selection.isValid
        ? math.min(math.max(newValue.selection.extentOffset, 0), raw.length)
        : raw.length;

    // Keep digits and the first dot; remember how many kept characters sit
    // after the cursor so it can be put back in the same place.
    final kept = StringBuffer();
    var keptAfterCursor = 0;
    var seenDot = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      final unit = ch.codeUnitAt(0);
      final isDigit = unit >= 48 && unit <= 57;
      final isDot = ch == '.' && decimals > 0 && !seenDot;
      if (!isDigit && !isDot) continue;
      if (isDot) seenDot = true;
      kept.write(ch);
      if (i >= rawCursor) keptAfterCursor++;
    }

    final text = kept.toString();
    final dotIndex = text.indexOf('.');
    var whole = dotIndex == -1 ? text : text.substring(0, dotIndex);
    var fraction = dotIndex == -1 ? '' : text.substring(dotIndex + 1);

    whole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final maxWhole = math.max(1, MoneyFormat.maxDigits - decimals);
    if (whole.length > maxWhole) whole = whole.substring(0, maxWhole);
    if (fraction.length > decimals) fraction = fraction.substring(0, decimals);
    if (whole.isEmpty && dotIndex != -1) whole = '0';

    final formatted =
        '${MoneyFormat.group(whole)}${dotIndex == -1 ? '' : '.$fraction'}';

    var offset = formatted.length;
    var remaining = keptAfterCursor;
    while (remaining > 0 && offset > 0) {
      offset--;
      if (formatted[offset] != ',') remaining--;
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
