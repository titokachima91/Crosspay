import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_constants.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/features/onboarding/screens/kyc_profile_screen.dart';
import 'package:crosspay_app/features/onboarding/screens/otp_verification_screen.dart';
import 'package:crosspay_app/features/onboarding/screens/phone_entry_screen.dart';
import 'package:crosspay_app/features/onboarding/screens/splash_language_screen.dart';
import 'package:crosspay_app/features/shell/main_shell_screen.dart';
import 'package:crosspay_app/features/transaction/screens/beneficiary_input_screen.dart';
import 'package:crosspay_app/features/transaction/screens/payment_prompt_screen.dart';
import 'package:crosspay_app/features/transaction/screens/route_selection_screen.dart';
import 'package:crosspay_app/features/transaction/screens/trade_tracker_screen.dart';
import 'package:crosspay_app/features/transaction/screens/invoice_screen.dart';
import 'package:crosspay_app/features/transaction/screens/route_comparison_screen.dart';
import 'package:crosspay_app/features/ledger/screens/transaction_history_screen.dart';
import 'package:crosspay_app/features/account/screens/security_settings_screen.dart';
import 'package:crosspay_app/features/account/screens/language_selector_screen.dart';

class CrossPayApp extends StatelessWidget {
  const CrossPayApp({super.key, this.builder});

  /// Optional wrapper drawn around every screen. The real app passes nothing;
  /// only the separate preview app uses it (to show its banner).
  final TransitionBuilder? builder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      builder: builder,
      initialRoute: AppRoutes.splash,
      routes: {
        AppRoutes.splash: (_) => const SplashLanguageScreen(),
        AppRoutes.phone: (_) => const PhoneEntryScreen(),
        AppRoutes.otp: (_) => const OtpVerificationScreen(),
        AppRoutes.kyc: (_) => const KycProfileScreen(),
        AppRoutes.home: (_) => const MainShellScreen(),
        AppRoutes.review: (_) => const RouteSelectionScreen(),
        AppRoutes.recipient: (_) => const BeneficiaryInputScreen(),
        AppRoutes.payment: (_) => const PaymentPromptScreen(),
        AppRoutes.tracker: (_) => const TradeTrackerScreen(),
        AppRoutes.invoice: (_) => const InvoiceScreen(),
        AppRoutes.compareRoutes: (_) => const RouteComparisonScreen(),
        AppRoutes.history: (_) => const TransactionHistoryScreen(),
        AppRoutes.security: (_) => const SecuritySettingsScreen(),
        AppRoutes.language: (_) => const LanguageSelectorScreen(),
      },
    );
  }
}
