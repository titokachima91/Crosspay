import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/utils/amount_input_formatter.dart';
import 'package:crosspay_app/core/utils/money_format.dart';

void main() {
  group('MoneyFormat.format', () {
    test('groups thousands and places the decimal point', () {
      expect(MoneyFormat.format(5000000, 0), '5,000,000');
      expect(MoneyFormat.format(25188917, 2), '251,889.17');
      expect(MoneyFormat.format(5, 2), '0.05');
      expect(MoneyFormat.format(0, 0), '0');
      expect(MoneyFormat.format(-1250, 2), '-12.50');
    });
  });

  group('MoneyFormat.parse', () {
    test('reads typed text back into whole smallest units', () {
      expect(MoneyFormat.parse('5,000,000', 0), 5000000);
      expect(MoneyFormat.parse('251,889.17', 2), 25188917);
      expect(MoneyFormat.parse('12.5', 2), 1250);
      expect(MoneyFormat.parse('.5', 2), 50);
      expect(MoneyFormat.parse('7.', 2), 700);
    });

    test('rejects empty, malformed or too precise text', () {
      expect(MoneyFormat.parse('', 2), isNull);
      expect(MoneyFormat.parse('.', 2), isNull);
      expect(MoneyFormat.parse('abc', 2), isNull);
      expect(MoneyFormat.parse('1.234', 2), isNull);
      expect(MoneyFormat.parse('1.5', 0), isNull);
      expect(MoneyFormat.parse('1234567890123456', 0), isNull);
    });
  });

  test('rate shows two decimals above one and four below', () {
    expect(MoneyFormat.rate(19.85), '19.85');
    expect(MoneyFormat.rate(0.0504), '0.0504');
  });

  group('AmountInputFormatter', () {
    TextEditingValue run(int decimals, String text, [int? cursor]) =>
        AmountInputFormatter(decimals: decimals).formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: cursor ?? text.length),
          ),
        );

    test('groups thousands as you type', () {
      expect(run(0, '1234567').text, '1,234,567');
      expect(run(2, '1234.5').text, '1,234.5');
    });

    test('limits the decimals and drops anything else', () {
      expect(run(2, '1234.567').text, '1,234.56');
      expect(run(0, '12.5').text, '125');
      expect(run(2, '1a2b').text, '12');
      expect(run(2, '1.2.3').text, '1.23');
    });

    test('removes leading zeros and completes a bare decimal point', () {
      expect(run(2, '0012').text, '12');
      expect(run(2, '.').text, '0.');
      expect(run(0, '0').text, '0');
    });

    test('keeps the cursor next to the digit being edited', () {
      expect(run(0, '12345', 5).selection.baseOffset, 6);
      expect(run(0, '1,2345', 1).selection.baseOffset, 1);
    });
  });
}
