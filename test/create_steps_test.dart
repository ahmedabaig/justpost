import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/blueprint_screen.dart';
import 'package:just_post/features/create/blueprint_service.dart';
import 'package:just_post/features/create/create_steps.dart';
import 'package:just_post/features/create/plan_service.dart';
import 'package:just_post/features/create/plans_screen.dart';
import 'package:just_post/theme/app_theme.dart';

import 'generation_service_test.dart' as gen;
import 'plan_editor_test.dart' as editor_test;

class _FakeBlueprintService extends BlueprintService {
  final List<Blueprint> saved = [];

  @override
  Future<ConfirmedBlueprint> save(String assetId, Blueprint blueprint) async {
    saved.add(blueprint);
    return ConfirmedBlueprint(blueprint: blueprint, version: saved.length + 2);
  }
}

class _FakePlanService extends PlanService {
  int plans = 0;

  @override
  Future<PlanRun> plan(String assetId, int count) async {
    plans++;
    return PlanRun.fromMap(
      Map<String, dynamic>.from(<Object?, Object?>{
        'assetId': gen.assetId,
        'runId': 'plan$plans',
        'status': 'failed',
        'count': count,
        'draft': null,
        'blueprintVersion': 2,
        'analysisRunId': 'run1',
        'confirmed': null,
        'rawExposed': false,
        'attempts': const <Object?>[],
      }),
    );
  }
}

BlueprintRun _blueprintRun() => BlueprintRun.fromMap(
  Map<String, dynamic>.from(<Object?, Object?>{
    'assetId': gen.assetId,
    'runId': 'bp1',
    'status': 'passed',
    'analysisRunId': 'run1',
    'draft': editor_test.blueprint().toMap(),
    'confirmed': null,
    'rawExposed': false,
    'attempts': const <Object?>[],
  }),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Step bar', () {
    Future<NavigatorState> pumpSteps(WidgetTester tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: buildJustPostTheme(),
          home: const Scaffold(body: Text('create tab')),
        ),
      );
      for (final step in CreateStep.values.take(4)) {
        navigator.currentState!.push(
          step.route<void>(
            (_) => Scaffold(
              key: Key('page-${step.name}'),
              body: SafeArea(child: CreateStepBar(current: step)),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }
      return navigator.currentState!;
    }

    testWidgets('goes straight back to an earlier step', (tester) async {
      await pumpSteps(tester);
      expect(find.byKey(const Key('page-images')), findsOneWidget);

      await tester.tap(find.byKey(const Key('step-blueprint')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page-blueprint')), findsOneWidget);
      expect(
        find.byKey(const Key('page-plans'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const Key('page-reference'), skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('later steps and the current one do nothing', (tester) async {
      await pumpSteps(tester);
      await tester.tap(find.byKey(const Key('step-set')));
      await tester.tap(find.byKey(const Key('step-images')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page-images')), findsOneWidget);
    });
  });

  group('Fix in blueprint', () {
    testWidgets('a rejected image passes on its reasons', (tester) async {
      final calls = <List<String>>[];
      await gen.pumpVariations(
        tester,
        gen.FakeGenerationService({
          'p1': gen.generationReply(status: 'rejected', inspect: false),
          'p2': gen.generationReply(planId: 'p2', status: 'failed'),
        }),
        onFixBlueprint: calls.add,
      );
      await tester.pump();

      await _tapVisible(tester, find.byKey(const Key('fix-blueprint-p1')));
      expect(calls, [
        ['Not allowed: Showing the face clearly'],
      ]);
    });

    testWidgets('warns before replacing images that passed', (tester) async {
      final calls = <List<String>>[];
      await gen.pumpVariations(
        tester,
        gen.FakeGenerationService({
          'p1': gen.generationReply(),
          'p2': gen.generationReply(planId: 'p2', status: 'failed'),
        }),
        renderService: gen.FakeRenderService([]),
        onFixBlueprint: calls.add,
      );
      await tester.pump();

      final fix = find.byKey(const Key('fix-blueprint-p1'));
      await tester.ensureVisible(fix);
      await tester.pump();
      await tester.tap(fix);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('The 1 image that passed will be replaced.'),
        findsOneWidget,
      );
      expect(find.textContaining('still being made'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, isEmpty);

      await tester.tap(fix);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('fix-blueprint-confirm')));
      await tester.pump();
      expect(calls, [<String>[]]);
    });

    testWidgets('returns to the blueprint and adds a Must keep rule', (
      tester,
    ) async {
      gen.tallScreen(tester);
      final blueprints = _FakeBlueprintService();
      final planner = _FakePlanService();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJustPostTheme(),
          home: BlueprintScreen(
            run: _blueprintRun(),
            service: blueprints,
            planService: planner,
            showInspection: false,
          ),
        ),
      );

      await _tapVisible(tester, find.byKey(const Key('save-blueprint-button')));
      await _tapVisible(
        tester,
        find.byKey(const Key('plan-variations-button')),
      );
      expect(find.byKey(const Key('plans-screen')), findsOneWidget);

      final plans = tester.widget<PlansScreen>(find.byType(PlansScreen));
      plans.onFixBlueprint!(['Missing: Shot inside a car']);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('plans-screen')), findsNothing);
      expect(find.text('Add to "Must keep"'), findsOneWidget);
      expect(
        find.textContaining('• Missing: Shot inside a car'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('text-edit-field')),
        'Shot from slightly above eye level',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('text-edit-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Shot from slightly above eye level'), findsOneWidget);

      await _tapVisible(tester, find.byKey(const Key('save-blueprint-button')));
      expect(
        blueprints.saved.last
            .items(BlueprintSection.mustKeep)
            .map((item) => item.text),
        contains('Shot from slightly above eye level'),
      );
      expect(find.text('Plan again'), findsOneWidget);

      await tester.tap(find.text('Plan again'));
      await tester.pumpAndSettle();
      expect(planner.plans, 2);
      expect(find.byKey(const Key('plans-screen')), findsOneWidget);
    });
  });
}
