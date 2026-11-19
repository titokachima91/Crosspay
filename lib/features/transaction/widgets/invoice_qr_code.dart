import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

/// The server-issued invoice QR image.
///
/// The PNG comes from `GET /api/v1/invoices/:token/qr.png`. The app never
/// paints a stand-in pattern: if the image is unavailable the payer is told to
/// use the link instead.
class InvoiceQrCode extends ConsumerWidget {
  const InvoiceQrCode({
    super.key,
    required this.qrCodeUrl,
    required this.reference,
  });

  final String qrCodeUrl;
  final String reference;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          width: 220,
          height: 220,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Image.network(
            qrCodeUrl,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
            semanticLabel: ref.tr('invoice.qr_label'),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (context, error, stackTrace) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_2, size: 48, color: scheme.error),
                  const SizedBox(height: 8),
                  Text(
                    ref.tr('invoice.qr_unavailable'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          ref.tr('invoice.scan'),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          reference,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}
