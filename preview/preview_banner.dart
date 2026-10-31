import 'package:flutter/material.dart';

/// A strip on top of every screen so nobody mistakes the preview for the real app.
class PreviewBanner extends StatelessWidget {
  const PreviewBanner({super.key, required this.child});

  final Widget child;

  static const Widget _strip = Material(
    color: Color(0xFFFFE082),
    child: SafeArea(
      bottom: false,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: Text(
            'PREVIEW: simulated data. SMS code: 1234',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5D4037),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _strip,
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
