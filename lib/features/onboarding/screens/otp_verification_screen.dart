import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';
import 'package:crosspay_app/core/constants/app_routes.dart';
import 'package:crosspay_app/core/utils/duration_format.dart';
import 'package:crosspay_app/core/utils/phone_utils.dart';
import 'package:crosspay_app/features/onboarding/widgets/pin_code_input_field.dart';
import 'package:crosspay_app/providers/auth_provider.dart';
import 'package:crosspay_app/providers/config_provider.dart';
import 'package:crosspay_app/providers/localization_provider.dart';
import 'package:crosspay_app/widgets/custom_button.dart';

/// Screen 1.3: SMS verification code entry.
class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({super.key});

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _timer;
  Duration _untilResend = Duration.zero;

  @override
  void initState() {
    super.initState();
    _untilResend = _computeUntilResend();
    _scheduleCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Duration _computeUntilResend() {
    final challenge = ref.read(authProvider).otpChallenge;
    if (challenge == null) return Duration.zero;
    final remaining = challenge.resendAvailableAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _scheduleCountdown() {
    _timer?.cancel();
    if (_untilResend == Duration.zero) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = _computeUntilResend();
      setState(() => _untilResend = remaining);
      if (remaining == Duration.zero) timer.cancel();
    });
  }

  void _onCodeChanged() {
    setState(() {});
    if (ref.read(authProvider).errorKey != null) {
      ref.read(authProvider.notifier).clearError();
    }
  }

  void _refocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    final verified =
        await ref.read(authProvider.notifier).verifyOtp(_codeController.text);
    if (!mounted) return;

    if (verified) {
      final complete = ref.read(authProvider).profileComplete ?? false;
      Navigator.of(context).pushNamedAndRemoveUntil(
        complete ? AppRoutes.home : AppRoutes.kyc,
        (route) => false,
      );
    } else {
      _codeController.clear();
      setState(() {});
      _refocusAfterFrame();
    }
  }

  Future<void> _resend() async {
    final phone = ref.read(authProvider).phone;
    if (phone == null) return;

    _codeController.clear();
    setState(() {});
    final sent = await ref.read(authProvider.notifier).requestOtp(phone);
    if (!mounted) return;

    if (sent) {
      setState(() => _untilResend = _computeUntilResend());
      _scheduleCountdown();
    }
    _refocusAfterFrame();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final countries = ref.watch(appConfigProvider).config.countries;
    final challenge = auth.otpChallenge;
    final phone = auth.phone;

    final appBar = AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.navy,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
    );

    if (challenge == null || phone == null) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              ref.tr('otp.no_request'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    final verifying = auth.status == AuthStatus.verifyingOtp;
    final busy = verifying || auth.status == AuthStatus.requestingOtp;
    final complete = _codeController.text.length == challenge.codeLength;

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ref.tr('otp.title'),
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          ref.tr('otp.subtitle', params: {
                            'length': '${challenge.codeLength}',
                            'phone':
                                PhoneUtils.formatInternational(phone, countries),
                          }),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 32),
                        Center(
                          child: PinCodeInputField(
                            controller: _codeController,
                            focusNode: _focusNode,
                            length: challenge.codeLength,
                            enabled: !busy,
                            hasError: auth.errorKey != null,
                            onChanged: (_) => _onCodeChanged(),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Center(
                          child: _untilResend > Duration.zero
                              ? Text(
                                  ref.tr('otp.resend_in', params: {
                                    'time': formatClock(_untilResend),
                                  }),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                )
                              : TextButton(
                                  onPressed: busy ? null : _resend,
                                  child: Text(ref.tr('otp.resend')),
                                ),
                        ),
                        if (auth.errorKey != null) ...[
                          const SizedBox(height: 16),
                          Center(
                            child: Text(
                              ref.trError(
                                key: auth.errorKey!,
                                code: auth.errorCode,
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.danger),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: CustomButton(
                    label: ref.tr('otp.verify'),
                    isLoading: verifying,
                    onPressed: (complete && !busy) ? _verify : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
