import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Translucent panel that blurs whatever sits behind it.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.height,
    this.padding,
    this.blurSigma = 18,
    this.tint = AppColors.glass,
    this.borderColor = AppColors.hairlineStrong,
    this.shadows = const [
      BoxShadow(
        color: Color(0x73000000),
        blurRadius: 30,
        offset: Offset(0, 14),
      ),
    ],
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;
  final Color tint;
  final Color borderColor;
  final List<BoxShadow> shadows;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            height: height,
            padding: padding,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor, width: 0.5),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
