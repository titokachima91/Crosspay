import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';

/// Theme mode options for the app.
enum AppThemeMode {
  light,
  dark,
  system,
}

/// The single place the two palettes are defined.
///
/// Screens must read colours from `Theme.of(context).colorScheme` (or the
/// `AppColors` status colours) rather than hardcoding light-theme values, so
/// both palettes stay readable.
class AppTheme {
  AppTheme._();

  // Dark palette. The interactive primary is the lighter indigo Material uses
  // for text/icons on dark surfaces, so swept screens remain legible; the app
  // bar sits on the dark surface colour.
  static const Color _darkBackground = Color(0xFF12121C);
  static const Color _darkSurface = Color(0xFF1E1E2E);
  static const Color _darkSurfaceHigh = Color(0xFF252538);
  static const Color _darkPrimary = Color(0xFF9FA8DA);
  static const Color _darkOnPrimary = Color(0xFF0A1033);
  static const Color _darkOnSurface = Color(0xFFF1F2F6);
  static const Color _darkOnSurfaceVariant = Color(0xFFB9BCCC);
  static const Color _darkOutline = Color(0xFF8A8DA0);
  static const Color _darkOutlineVariant = Color(0xFF3A3D52);
  static const Color _darkError = Color(0xFFFF8A80);

  static OutlineInputBorder _border(Color color, double width) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.navy,
      onPrimary: Colors.white,
      secondary: AppColors.emerald,
      onSecondary: Colors.black,
      error: AppColors.danger,
      // Keep the verified light look exactly as it was before the theme work.
      surface: Colors.white,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      outlineVariant: AppColors.border,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size.fromHeight(52), // 52dp CTA from the spec
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _border(scheme.outlineVariant, 1),
        enabledBorder: _border(scheme.outlineVariant, 1),
        focusedBorder: _border(scheme.primary, 2),
        errorBorder: _border(scheme.error, 1),
      ),
    );
  }

  /// Dark theme with the same typography and shapes as [light].
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _darkPrimary,
      onPrimary: _darkOnPrimary,
      secondary: AppColors.emerald,
      onSecondary: Colors.black,
      error: _darkError,
      onError: Colors.black,
      surface: _darkSurface,
      onSurface: _darkOnSurface,
      onSurfaceVariant: _darkOnSurfaceVariant,
      surfaceContainerHighest: _darkSurfaceHigh,
      outline: _darkOutline,
      outlineVariant: _darkOutlineVariant,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: _darkBackground,
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _darkSurface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _darkSurfaceHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _border(scheme.outlineVariant, 1),
        enabledBorder: _border(scheme.outlineVariant, 1),
        focusedBorder: _border(scheme.primary, 2),
        errorBorder: _border(scheme.error, 1),
      ),
    );
  }

  /// Returns the appropriate theme based on [mode] and platform brightness.
  static ThemeData forMode(AppThemeMode mode, {Brightness? platformBrightness}) {
    switch (mode) {
      case AppThemeMode.light:
        return AppTheme.light;
      case AppThemeMode.dark:
        return AppTheme.dark;
      case AppThemeMode.system:
        return platformBrightness == Brightness.dark
            ? AppTheme.dark
            : AppTheme.light;
    }
  }
}
