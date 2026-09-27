import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pressable.dart';

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.activeIcon,
    this.isAction = false,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool isAction;
}

/// Glass capsule that floats over the page content.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const double barHeight = 66;
  static const double _sideInset = 20;
  static const double _maxWidth = 420;

  static const _destinations = [
    _Destination(
      label: 'Library',
      icon: CupertinoIcons.rectangle_stack,
      activeIcon: CupertinoIcons.rectangle_stack_fill,
    ),
    _Destination(
      label: 'Upload Slides',
      icon: CupertinoIcons.plus,
      activeIcon: CupertinoIcons.plus,
      isAction: true,
    ),
    _Destination(
      label: 'You',
      icon: CupertinoIcons.person,
      activeIcon: CupertinoIcons.person_fill,
    ),
  ];

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Vertical space the pill occupies, so page content can reserve room for it.
  static double reservedHeight(BuildContext context) =>
      barHeight + _bottomGap(MediaQuery.viewPaddingOf(context).bottom) + 10;

  // Devices with a home indicator already leave room at the bottom, so only
  // half of that inset is added; stacking all of it floats the pill too high.
  static double _bottomGap(double safeBottom) =>
      14 + math.max(0.0, safeBottom - 20) / 2;

  @override
  Widget build(BuildContext context) {
    final bottomGap = _bottomGap(MediaQuery.viewPaddingOf(context).bottom);

    return Padding(
      padding: EdgeInsets.fromLTRB(_sideInset, 0, _sideInset, bottomGap),
      child: SizedBox(
        height: barHeight,
        width: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: GlassSurface(
              height: barHeight,
              borderRadius: BorderRadius.circular(barHeight / 2),
              blurSigma: 16,
              borderColor: AppColors.hairlineStrong,
              shadows: const [
                BoxShadow(
                  color: Color(0x1A1C1922),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
              child: Row(
                children: [
                  for (var i = 0; i < _destinations.length; i++)
                    Expanded(
                      child: _NavItem(
                        destination: _destinations[i],
                        selected: i == selectedIndex,
                        onTap: () => onSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (destination.isAction) {
      return Semantics(
        key: const Key('upload-slides-button'),
        button: true,
        label: destination.label,
        child: Pressable(
          onTap: onTap,
          scale: 0.9,
          child: const Center(child: _NavPlus()),
        ),
      );
    }

    final color = selected ? AppColors.accent : AppColors.textTertiary;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: Pressable(
        onTap: onTap,
        scale: 0.92,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: selected ? 1.06 : 1,
              duration: AppMotion.base,
              curve: Curves.easeOutBack,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: color),
                duration: AppMotion.base,
                builder: (context, value, _) => Icon(
                  selected ? destination.activeIcon : destination.icon,
                  size: 21,
                  color: value,
                ),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: AppMotion.base,
              style: TextStyle(
                color: color,
                fontSize: 11,
                height: 1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.1,
              ),
              child: Text(destination.label),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavPlus extends StatelessWidget {
  const _NavPlus();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(
            color: Color(0x261F1717),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: const SizedBox(
        width: 20,
        height: 20,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            SizedBox(
              width: 3,
              height: 20,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
