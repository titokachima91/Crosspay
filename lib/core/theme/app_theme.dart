import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';

/// Theme mode options for the app.
enum AppThemeMode {
  light,
  dark,
  system,
}

class AppTheme {
  AppTheme._();

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
      onSecondary: Colors.white,
      error: AppColors.danger,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: AppColors.navy,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
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
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52), // 52dp CTA from the spec
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _border(AppColors.border, 1),
        enabledBorder: _border(AppColors.border, 1),
        focusedBorder: _border(AppColors.navy, 2),
        errorBorder: _border(AppColors.danger, 1),
      ),
    );
  }

  /// Dark theme with Material3 color scheme.
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.navy,
      onPrimary: Colors.white,
      secondary: AppColors.emerald,
      onSecondary: Colors.white,
      error: AppColors.danger,
      surface: const Color(0xFF1E1E2E),
      onSurface: Colors.white,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: AppColors.navy,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
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
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _border(AppColors.border, 1),
        enabledBorder: _border(AppColors.border, 1),
        focusedBorder: _border(AppColors.navy, 2),
        errorBorder: _border(AppColors.danger, 1),
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
