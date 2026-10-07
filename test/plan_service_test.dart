import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/blueprint_screen.dart';
import 'package:just_post/features/create/blueprint_service.dart';
import 'package:just_post/features/create/plan_service.dart';
import 'package:just_post/features/create/plans_screen.dart';
import 'package:just_post/theme/app_theme.dart';

import 'plan_editor_test.dart' as editor_test;

const _raw = '{"schemaVersion": 1, "plans": []}';

/// Shaped like the server's plan set, with the untyped maps callables return.
Map<Object?, Object?> _planSetMap({int blueprintVersion = 2}) => {
  'schemaVersion': 1,
  'analysisRunId': 'run1',
  'blueprintVersion': blueprintVersion,
  'plans': [
    <Object?, Object?>{
      'id': 'p1',
      'origin': 'ai',
      'title': 'Cozy coffee run',
      'changes': [
        <Object?, Object?>{'dimensionId': 'var1', 'value': 'warm cream'},
        <Object?, Object?>{'dimensionId': 'var2', 'value': 'iced coffee'},
      ],
      'copy': <Object?, Object?>{
        'text': 'POV: your lock screen teaches you',
        'pattern': 'POV',
      },
    },
    <Object?, Object?>{
      'id': 'p2',
      'origin': 'ai',
      'title': 'Matcha and flowers',
      'changes': [
        <Object?, Object?>{'dimensionId': 'var2', 'value': 'matcha latte'},
      ],
      'copy': <Object?, Object?>{
        'text': 'How to put the 99 Names on your lock screen',
        'pattern': 'how-to',
      },
    },
  ],
};

PlanRun _run({
  String status = 'passed',
  bool rawExposed = true,
  Map<Object?, Object?>? confirmed,
}) => PlanRun.fromMap(
  Map<String, dynamic>.from(<Object?, Object?>{
    'assetId': 'abcdefghij0123456789',
    'runId': 'plan1',
    'status': status,
    'count': 2,
    'draft': status == 'passed' ? _planSetMap() : null,
    'blueprintVersion': 2,
    'analysisRunId': 'run1',
    'confirmed': confirmed,
    'rawExposed': rawExposed,
    'attempts': [
      <Object?, Object?>{
        'status': status,
        'issues': status == 'passed' ? [] : ['plans: write exactly 2, not 1'],
        'model': 'test-model',
        'latencyMs': 4200,
        if (rawExposed) 'rawText': _raw,
      },
    ],
  }),
);

/// The screen's list; selectable text adds scrollables of its own.
final _page = find.byType(Scrollable).first;

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, PlanRun run, bool inspect) async {
  _tallScreen(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildJustPostTheme(),
      home: PlansScreen(
        run: run,
        blueprint: editor_test.blueprint(),
        service: PlanService(),
        showInspection: inspect,
      ),
    ),
  );
}

void main() {
  test('PlanSet round-trips through toMap in the server\'s shape', () {
    final source = Map<String, dynamic>.from(_planSetMap());
    final plans = PlanSet.fromMap(source);

    expect(plans.blueprintVersion, 2);
    expect(plans.plans.first.changes.last.value, 'iced coffee');
    expect(plans.plans.last.copy!.pattern, 'how-to');

    final map = plans.toMap();
    expect(map['plans'][0], {
      'id': 'p1',
      'origin': 'ai',
      'title': 'Cozy coffee run',
      'changes': [
        {'dimensionId': 'var1', 'value': 'warm cream'},
        {'dimensionId': 'var2', 'value': 'iced coffee'},
      ],
      'copy': {'text': 'POV: your lock screen teaches you', 'pattern': 'POV'},
    });
    expect(PlanSet.fromMap(map).toMap(), map);
  });

  test('PlanRun reads the plan_variations reply', () {
    final run = _run(
      confirmed: {'plans': _planSetMap(blueprintVersion: 1), 'version': 3},
    );
    expect(run.passed, isTrue);
    expect(run.count, 2);
    expect(run.draft!.plans, hasLength(2));
    expect(run.confirmed!.version, 3);
    expect(run.confirmed!.plans.blueprintVersion, 1);
    expect(run.attempts.single.rawText, _raw);

    final failed = _run(status: 'failed');
    expect(failed.passed, isFalse);
    expect(failed.draft, isNull);
  });

  testWidgets('the screen shows the editable plans and the raw output', (
    tester,
  ) async {
    await _pump(tester, _run(), true);

    expect(find.text('Check passed'), findsOneWidget);
    expect(find.text('Cozy coffee run'), findsOneWidget);
    expect(find.text('Hijab color'), findsOneWidget);
    expect(find.text('warm cream'), findsOneWidget);
    expect(find.text('POV: your lock screen teaches you'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('raw-output-panel')),
      300,
      scrollable: _page,
    );
    expect(find.text(_raw), findsOneWidget);
    expect(find.text('Plan again (2 plans)'), findsOneWidget);
  });

  testWidgets('the raw panel is hidden when the inspection flag is off', (
    tester,
  ) async {
    await _pump(tester, _run(), false);
    expect(find.byKey(const Key('raw-output-panel')), findsNothing);
  });

  testWidgets('removing a change and deleting a plan update the screen', (
    tester,
  ) async {
    await _pump(tester, _run(), false);

    await tester.tap(find.byTooltip('Change options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('warm cream'), findsNothing);
    expect(find.text('iced coffee'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete plan').last);
    await tester.pumpAndSettle();
    expect(find.text('Matcha and flowers'), findsNothing);
    expect(find.text('Plan 2'), findsNothing);
  });

  testWidgets('switching a change to another dimension', (tester) async {
    await _pump(tester, _run(), false);

    await tester.tap(find.byTooltip('Change options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change Phone case instead'));
    await tester.pumpAndSettle();

    expect(find.text('Phone case'), findsOneWidget);
    expect(find.text('warm cream'), findsOneWidget);
  });

  testWidgets('confirmed plans from an earlier blueprint are noted', (
    tester,
  ) async {
    await _pump(
      tester,
      _run(
        confirmed: {'plans': _planSetMap(blueprintVersion: 1), 'version': 2},
      ),
      false,
    );
    expect(find.text('Confirmed, version 2 · 2 plans'), findsOneWidget);
    expect(
      find.text('Written for an earlier version of the blueprint.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed run shows the reasons and no editor', (tester) async {
    await _pump(tester, _run(status: 'failed'), true);
    expect(find.text('Check failed'), findsOneWidget);
    expect(find.text('• plans: write exactly 2, not 1'), findsOneWidget);
    expect(find.byKey(const Key('save-plans-button')), findsNothing);
  });

  group('Plan variations on the Blueprint screen', () {
    final confirmed = <Object?, Object?>{
      'blueprint': editor_test.blueprint().toMap(),
      'version': 2,
    };

    BlueprintRun blueprintRun({required String status}) => BlueprintRun.fromMap(
      Map<String, dynamic>.from(<Object?, Object?>{
        'assetId': 'abcdefghij0123456789',
        'runId': 'bp1',
        'status': status,
        'analysisRunId': 'run1',
        'draft': status == 'passed' ? confirmed['blueprint'] : null,
        'confirmed': confirmed,
        'rawExposed': false,
        'attempts': const [],
      }),
    );

    Future<void> pumpBlueprint(WidgetTester tester, BlueprintRun run) async {
      _tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJustPostTheme(),
          home: BlueprintScreen(
            run: run,
            service: BlueprintService(),
            showInspection: false,
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('plan-variations-button')),
        300,
        scrollable: _page,
      );
    }

    testWidgets('waits until the draft is saved', (tester) async {
      await pumpBlueprint(tester, blueprintRun(status: 'passed'));
      expect(
        find.text('Save the blueprint to plan variations.'),
        findsOneWidget,
      );
    });

    testWidgets('is ready with a confirmed blueprint for this analysis', (
      tester,
    ) async {
      await pumpBlueprint(tester, blueprintRun(status: 'failed'));
      expect(find.byKey(const Key('plan-blocker')), findsNothing);
      expect(find.byKey(const Key('plan-count')), findsOneWidget);
    });
  });
}
