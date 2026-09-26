import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Tap target that dips slightly while held.
///
/// Used instead of Material ink so touch feedback reads the same on iOS and
/// Android, and so it can sit inside translucent chrome without a ripple
/// bleeding across the blur.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.96,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _held = false;

  bool get _enabled => widget.onTap != null;

  void _setHeld(bool value) {
    if (_held == value) return;
    setState(() => _held = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _setHeld(true) : null,
      onTapUp: _enabled ? (_) => _setHeld(false) : null,
      onTapCancel: _enabled ? () => _setHeld(false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _held ? widget.scale : 1,
        duration: AppMotion.quick,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
