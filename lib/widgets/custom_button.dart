import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';

/// Primary 52dp call-to-action button (height comes from the theme).
class CustomButton extends StatelessWidget {
  const CustomButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;

  /// Emerald instead of navy, for confirm-type actions.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      style: accent
          ? ElevatedButton.styleFrom(
              backgroundColor: AppColors.emerald,
              foregroundColor: scheme.onSecondary,
            )
          : null,
      child: isLoading
          ? SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: accent ? scheme.onSecondary : scheme.onPrimary,
              ),
            )
          : Text(label),
    );
  }
}
