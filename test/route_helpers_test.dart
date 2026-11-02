import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/utils/money_format.dart';

void main() {
  test('basis points become a tidy percentage', () {
    expect(MoneyFormat.percentFromBps(150), '1.5%');
    expect(MoneyFormat.percentFromBps(280), '2.8%');
    expect(MoneyFormat.percentFromBps(100), '1%');
    expect(MoneyFormat.percentFromBps(125), '1.25%');
    expect(MoneyFormat.percentFromBps(5), '0.05%');
    expect(MoneyFormat.percentFromBps(0), '0%');
  });
}
