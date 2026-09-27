import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Shared page canvas.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: AppColors.canvas, child: child);
  }
}
