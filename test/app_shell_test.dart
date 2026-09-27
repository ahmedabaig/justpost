import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/shell/app_shell.dart';
import 'package:just_post/shell/floating_nav_bar.dart';
import 'package:just_post/theme/app_theme.dart';

void main() {
  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildJustPostTheme(), home: const AppShell()),
    );
    await tester.pumpAndSettle();
  }

  int? selectedIndex(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack)).index;

  Finder navItem(String label) => find.descendant(
    of: find.byType(FloatingNavBar),
    matching: find.text(label),
  );

  testWidgets('opens on Create with the pill floating over the page', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(selectedIndex(tester), 1);
    expect(find.byType(FloatingNavBar), findsOneWidget);
    expect(find.byKey(const Key('upload-slides-button')), findsOneWidget);

    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final barRect = tester.getRect(find.byType(FloatingNavBar));
    expect(barRect.center.dy, greaterThan(screenHeight * 0.75));
  });

  testWidgets('tapping a destination switches tabs', (tester) async {
    await pumpShell(tester);

    await tester.tap(navItem('Library'));
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), 0);

    await tester.tap(navItem('You'));
    await tester.pumpAndSettle();
    expect(selectedIndex(tester), 2);
  });

  testWidgets('pages stay mounted so tab state survives switching', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(navItem('You'));
    await tester.pumpAndSettle();

    // The Create page is still in the tree behind the active tab.
    expect(
      find.byKey(const Key('create-screen'), skipOffstage: false),
      findsOneWidget,
    );
  });
}
