import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/utils/duration_format.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/models/app_config_model.dart';

// Test inputs only. Not app data.
const _short = Country(
  code: 'AA',
  name: 'Short',
  dialCode: '1',
  nationalNumberLength: 7,
);
const _long = Country(
  code: 'BB',
  name: 'Long',
  dialCode: '12',
  nationalNumberLength: 6,
);

void main() {
  group('formatInternational', () {
    test('groups the national part after the calling code', () {
      expect(
        PhoneUtils.formatInternational('+999712345678', const [
          Country(
            code: 'ZZ',
            name: 'Testland',
            dialCode: '999',
            nationalNumberLength: 9,
          ),
        ]),
        '+999 712 345 678',
      );
    });

    test('the longest matching calling code wins', () {
      expect(
        PhoneUtils.formatInternational('+12345678', const [_short, _long]),
        '+12 345 678',
      );
    });

    test('an unknown calling code leaves the number unchanged', () {
      expect(
        PhoneUtils.formatInternational('+777123456', const [_short, _long]),
        '+777123456',
      );
    });
  });

  test('groupDigits splits in threes', () {
    expect(PhoneUtils.groupDigits('1234567'), '123 456 7');
    expect(PhoneUtils.groupDigits(''), '');
  });

  group('formatClock', () {
    test('formats minutes and seconds', () {
      expect(formatClock(const Duration(seconds: 30)), '00:30');
      expect(formatClock(const Duration(seconds: 61)), '01:01');
    });

    test('rounds partial seconds up, never below zero', () {
      expect(formatClock(const Duration(milliseconds: 29500)), '00:30');
      expect(formatClock(Duration.zero), '00:00');
      expect(formatClock(const Duration(seconds: -5)), '00:00');
    });
  });
}
