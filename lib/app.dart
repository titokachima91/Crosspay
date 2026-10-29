import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_constants.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/onboarding/screens/phone_entry_screen.dart';
import 'package:crosspay_app/features/onboarding/screens/splash_language_screen.dart';

class CrossPayApp extends StatelessWidget {
  const CrossPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      initialRoute: AppRoutes.splash,
      routes: {
        AppRoutes.splash: (_) => const SplashLanguageScreen(),
        AppRoutes.phone: (_) => const PhoneEntryScreen(),
        AppRoutes.otp: (_) =>
            const _NextStepScreen(label: 'Next: F2.3 OTP verification'),
      },
    );
  }
}

// TEMPORARY: replaced by the real OTP screen in F2.3.
class _NextStepScreen extends StatelessWidget {
  const _NextStepScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppConstants.appName)),
      body: Center(child: Text('$label (temporary screen)')),
    );
  }
}
