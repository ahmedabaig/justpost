import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Deep canvas with two soft brand glows.
///
/// Beyond setting the mood this gives the blurred chrome something to pick up,
/// so the navigation pill reads as glass rather than a flat dark bar.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.canvas),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned(
            top: -170,
            right: -110,
            child: _Glow(
              diameter: 420,
              color: Color(0xFF7C5CFF),
              opacity: 0.30,
            ),
          ),
          const Positioned(
            bottom: -210,
            left: -150,
            child: _Glow(
              diameter: 470,
              color: Color(0xFF3B1E9E),
              opacity: 0.34,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({
    required this.diameter,
    required this.color,
    required this.opacity,
  });

  final double diameter;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}
