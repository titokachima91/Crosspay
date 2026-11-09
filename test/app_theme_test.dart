import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';

/// WCAG relative contrast: 4.5 is the AA threshold for normal text.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void _expectReadable(ColorScheme scheme, String palette) {
  expect(
    _contrast(scheme.surface, scheme.onSurface),
    greaterThanOrEqualTo(4.5),
    reason: '$palette: body text on surface must be readable',
  );
  expect(
    _contrast(scheme.primary, scheme.onPrimary),
    greaterThanOrEqualTo(4.5),
    reason: '$palette: text on primary must be readable',
  );
  expect(
    _contrast(scheme.secondary, scheme.onSecondary),
    greaterThanOrEqualTo(4.5),
    reason: '$palette: text on secondary must be readable',
  );
  expect(
    _contrast(scheme.error, scheme.onError),
    greaterThanOrEqualTo(4.5),
    reason: '$palette: text on error must be readable',
  );
}

void main() {
  test('both palettes keep text readable', () {
    _expectReadable(AppTheme.light.colorScheme, 'light');
    _expectReadable(AppTheme.dark.colorScheme, 'dark');
  });

  test('light and dark actually differ in brightness', () {
    expect(AppTheme.light.brightness, Brightness.light);
    expect(AppTheme.dark.brightness, Brightness.dark);

    expect(AppTheme.light.scaffoldBackgroundColor.computeLuminance(),
        greaterThan(0.8));
    expect(AppTheme.dark.scaffoldBackgroundColor.computeLuminance(),
        lessThan(0.1));
  });

  test('the dark theme no longer paints light-theme surfaces', () {
    final scheme = AppTheme.dark.colorScheme;

    expect(scheme.surface.computeLuminance(), lessThan(0.1));
    expect(
      AppTheme.dark.inputDecorationTheme.fillColor!.computeLuminance(),
      lessThan(0.1),
    );
    expect(
      scheme.onSurface.computeLuminance(),
      greaterThan(0.7),
      reason: 'dark-mode text must be light',
    );
    expect(
      AppTheme.dark.textTheme.bodyMedium?.color,
      scheme.onSurfaceVariant,
      reason: 'body text must come from the scheme, not AppColors',
    );
  });
}
