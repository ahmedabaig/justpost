import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/create/create_screen.dart';
import '../features/library/library_screen.dart';
import '../features/profile/profile_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/ambient_background.dart';
import 'floating_nav_bar.dart';

/// Root layout: one surface, three long-lived pages, and a floating navigation
/// pill layered over them.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const int _createIndex = 1;

  final ValueNotifier<int> _uploadRequests = ValueNotifier(0);
  int _selectedIndex = _createIndex;

  void _select(int index) {
    if (index == _createIndex) {
      HapticFeedback.mediumImpact();
      if (_selectedIndex != _createIndex) {
        setState(() => _selectedIndex = _createIndex);
      }
      _uploadRequests.value++;
      return;
    }

    if (index == _selectedIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedIndex = index);
  }

  @override
  void dispose() {
    _uploadRequests.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final reserved = FloatingNavBar.reservedHeight(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarBrightness: Brightness.light,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        extendBody: true,
        backgroundColor: AppColors.canvas,
        body: AmbientBackground(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Pages stay mounted so each tab keeps its own state, and they see
              // a bottom inset wide enough to clear the floating pill.
              MediaQuery(
                data: mediaQuery.copyWith(
                  padding: mediaQuery.padding.copyWith(
                    bottom: math.max(mediaQuery.padding.bottom, reserved),
                  ),
                ),
                child: _FadeThroughStack(
                  index: _selectedIndex,
                  children: [
                    const LibraryScreen(),
                    CreateScreen(uploadRequests: _uploadRequests),
                    const ProfileScreen(),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FloatingNavBar(
                  selectedIndex: _selectedIndex,
                  onSelected: _select,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [IndexedStack] that settles the incoming tab in with a short fade and rise,
/// so switching tabs never hard-cuts.
class _FadeThroughStack extends StatefulWidget {
  const _FadeThroughStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_FadeThroughStack> createState() => _FadeThroughStackState();
}

class _FadeThroughStackState extends State<_FadeThroughStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
    value: 1,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.enter,
  );

  @override
  void didUpdateWidget(_FadeThroughStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) {
        final t = _progress.value;
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: child,
          ),
        );
      },
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
