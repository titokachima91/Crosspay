import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the real app never imports the preview folder', () {
    final importsPreview = RegExp(r'''import\s+['"][^'"]*preview/''');
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (importsPreview.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });
}
