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
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
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
      label: 'Create',
      icon: CupertinoIcons.sparkles,
      activeIcon: CupertinoIcons.sparkles,
    ),
    _Destination(
      label: 'Library',
      icon: CupertinoIcons.rectangle_stack,
      activeIcon: CupertinoIcons.rectangle_stack_fill,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth / _destinations.length;

                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: AppMotion.base,
                        curve: AppMotion.enter,
                        left: itemWidth * selectedIndex,
                        width: itemWidth,
                        top: 0,
                        bottom: 0,
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: _SelectionCapsule(),
                        ),
                      ),
                      Row(
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
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionCapsule extends StatelessWidget {
  const _SelectionCapsule();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x2EFFFFFF), Color(0x12FFFFFF)],
        ),
        border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
        boxShadow: const [
          BoxShadow(color: Color(0x4D7C5CFF), blurRadius: 20, spreadRadius: -4),
        ],
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
    final color = selected ? AppColors.textPrimary : AppColors.textTertiary;

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
