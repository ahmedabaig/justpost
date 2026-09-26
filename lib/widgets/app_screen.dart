import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared page chrome: a large title (or brand lockup), trailing actions, and
/// a body that fills the rest of the shell.
///
/// Pages intentionally do not create their own [Scaffold]; the shell owns the
/// single surface so the ambient background shows through every tab.
class AppScreen extends StatelessWidget {
  const AppScreen({
    super.key,
    required this.child,
    this.title,
    this.leading,
    this.actions = const [],
  }) : assert(
         title != null || leading != null,
         'A screen needs either a title or a leading lockup.',
       );

  final Widget child;
  final String? title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading =
        leading ??
        Text(
          title!,
          style: Theme.of(context).textTheme.headlineMedium,
          overflow: TextOverflow.ellipsis,
        );

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: heading),
                ),
                ...actions,
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Scrollable body whose content is vertically centred when it is shorter than
/// the viewport, and scrolls normally when it is not.
class CenteredScrollBody extends StatelessWidget {
  const CenteredScrollBody({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - padding.vertical),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: children,
            ),
          ),
        );
      },
    );
  }
}
