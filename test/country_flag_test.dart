import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/utils/country_flag.dart';

void main() {
  test('turns a country code into a flag, ignoring case', () {
    final expected = String.fromCharCodes([0x1F1F9, 0x1F1FF]);
    expect(countryFlag('TZ'), expected);
    expect(countryFlag('tz'), expected);
  });

  test('returns nothing for anything that is not two letters', () {
    expect(countryFlag(''), '');
    expect(countryFlag('T'), '');
    expect(countryFlag('TZA'), '');
    expect(countryFlag('T1'), '');
  });
}
