import 'package:flutter/material.dart';
import 'package:crosspay_app/core/constants/app_colors.dart';

/// Visual QR code representation for invoice sharing.
/// In production this would use a QR code package like qr_flutter.
class InvoiceQrCode extends StatelessWidget {
  const InvoiceQrCode({
    super.key,
    required this.tradeId,
    required this.reference,
    required this.amount,
    required this.currency,
  });

  final String tradeId;
  final String reference;
  final int amount;
  final String currency;

  // Generate a simple deterministic QR-like pattern from tradeId
  List<bool> _qrPattern() {
    final pattern = <bool>[];
    final hash = tradeId.hashCode.abs();
    for (int i = 0; i < 25 * 25; i++) {
      pattern.add(((hash >> (i % 32)) & 1) == 1);
    }
    return pattern;
  }

  @override
  Widget build(BuildContext context) {
    final pattern = _qrPattern();
    const size = 200.0;
    const cellSize = size / 25;

    return Column(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: CustomPaint(
            size: const Size(size, size),
            painter: _QrPainter(pattern: pattern, cellSize: cellSize),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Scan to pay',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          reference,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Valid for 24 hours',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  final List<bool> pattern;
  final double cellSize;

  _QrPainter({required this.pattern, required this.cellSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = AppColors.navy;
    for (int i = 0; i < pattern.length; i++) {
      if (!pattern[i]) continue;
      final row = i ~/ 25;
      final col = i % 25;
      final x = col * cellSize;
      final y = row * cellSize;
      canvas.drawRect(
        Rect.fromLTWH(x, y, cellSize, cellSize),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => true;
}