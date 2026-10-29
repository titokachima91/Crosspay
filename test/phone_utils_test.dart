import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/utils/national_number_formatter.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/models/app_config_model.dart';

// Test inputs only. Not app data.
const _country = Country(
  code: 'ZZ',
  name: 'Testland',
  dialCode: '999',
  nationalNumberLength: 9,
);

const _carrierA = Carrier(
  id: 'a',
  name: 'Carrier A',
  countryCode: 'ZZ',
  prefixPattern: '^71',
);
const _carrierB = Carrier(
  id: 'b',
  name: 'Carrier B',
  countryCode: 'ZZ',
  prefixPattern: '^75',
);
const _otherCountry = Carrier(
  id: 'o',
  name: 'Elsewhere',
  countryCode: 'YY',
  prefixPattern: '^76',
);
const _broken = Carrier(
  id: 'x',
  name: 'Broken',
  countryCode: 'ZZ',
  prefixPattern: '(',
);

void main() {
  group('PhoneUtils', () {
    test('keeps digits only and drops leading zeros', () {
      expect(PhoneUtils.normalizeNational('0712 345-678'), '712345678');
      expect(PhoneUtils.normalizeNational('000'), '');
      expect(PhoneUtils.normalizeNational(''), '');
    });

    test('builds the international number', () {
      expect(
        PhoneUtils.toInternational(_country, '0712 345 678'),
        '+999712345678',
      );
    });

    test('knows when a number is complete', () {
      expect(PhoneUtils.isComplete(_country, '712 345 678'), true);
      expect(PhoneUtils.isComplete(_country, '712 345 67'), false);
    });

    test('suggests a carrier from the prefix', () {
      const carriers = [_carrierA, _carrierB, _otherCountry, _broken];

      Carrier? detect(String input) => PhoneUtils.detectCarrier(
            country: _country,
            input: input,
            carriers: carriers,
          );

      expect(detect('712345678'), _carrierA);
      expect(detect('0752345678'), _carrierB);
      expect(detect('762345678'), isNull); // other country's carrier ignored
      expect(detect('171234567'), isNull); // must match from the start
      expect(detect(''), isNull);
    });

    test('a broken pattern from the server is skipped, not fatal', () {
      final result = PhoneUtils.detectCarrier(
        country: _country,
        input: '712345678',
        carriers: const [_broken, _carrierA],
      );
      expect(result, _carrierA);
    });
  });

  group('NationalNumberFormatter', () {
    final formatter = NationalNumberFormatter(maxDigits: 9);

    TextEditingValue run(String text, [int? cursor]) =>
        formatter.formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: cursor ?? text.length),
          ),
        );

    test('groups digits in threes', () {
      final value = run('712345678');
      expect(value.text, '712 345 678');
      expect(value.selection.baseOffset, 11);
    });

    test('drops a leading zero and non-digits', () {
      expect(run('0712345678').text, '712 345 678');
      expect(run('7a1').text, '71');
      expect(run('0').text, '');
    });

    test('caps the length', () {
      expect(run('7123456789').text, '712 345 678');
    });

    test('keeps the cursor next to the digit being edited', () {
      expect(run('7123', 2).selection.baseOffset, 2);
      expect(run('7123', 4).selection.baseOffset, 5);
    });
  });
}
