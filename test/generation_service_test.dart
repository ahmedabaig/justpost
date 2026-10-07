import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/generation_service.dart';
import 'package:just_post/features/create/plan_service.dart';
import 'package:just_post/features/create/plans_screen.dart';
import 'package:just_post/features/create/render_service.dart';
import 'package:just_post/features/create/variations_screen.dart';
import 'package:just_post/features/library/slideshow_service.dart';
import 'package:just_post/theme/app_theme.dart';

import 'plan_editor_test.dart' as editor_test;

const assetId = 'abcdefghij0123456789';

/// A `generate_variation` reply. [inspect] is the server's inspection switch:
/// passed images are always shown, others only with it on.
Map<Object?, Object?> generationReply({
  String planId = 'p1',
  String status = 'passed',
  bool inspect = true,
}) {
  final shown = status == 'passed' || (status != 'failed' && inspect);
  return {
    'assetId': assetId,
    'planId': planId,
    'runId': 'gen-$planId',
    'status': status,
    'issues': switch (status) {
      'failed' => ['The image is blank or a single color.'],
      'rejected' => ['Not allowed: Showing the face clearly'],
      'unverified' => ["The image couldn't be checked."],
      _ => <String>[],
    },
    'checks': status == 'failed' || status == 'unverified'
        ? <Object?>[]
        : [
            <Object?, Object?>{
              'id': 'required:req1',
              'kind': 'required',
              'question': 'Is this still true? Shot inside a car',
              'answer': 'yes',
              'passed': true,
              if (inspect) 'note': 'Dashboard visible.',
            },
            <Object?, Object?>{
              'id': 'forbidden:never2',
              'kind': 'forbidden',
              'question': 'Has this happened? Showing the face clearly',
              'answer': status == 'rejected' ? 'yes' : 'no',
              'passed': status != 'rejected',
            },
          ],
    'model': 'gpt-image-test',
    'latencyMs': 42000,
    'plansVersion': 3,
    'width': status == 'failed' ? null : 704,
    'height': status == 'failed' ? null : 1536,
    'imageExposed': shown,
    'imagePath': shown ? 'uploads/u/$assetId/variations/gen-$planId.png' : null,
  };
}

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
      ],
      'copy': <Object?, Object?>{
        'text': 'POV: your lock screen teaches you',
        'pattern': 'POV',
      },
    },
    <Object?, Object?>{
      'id': 'p2',
      'origin': 'user',
      'title': 'Matcha and flowers',
      'changes': [
        <Object?, Object?>{'dimensionId': 'var2', 'value': 'matcha latte'},
      ],
      'copy': null,
    },
  ],
};

ConfirmedPlans confirmedPlans({int blueprintVersion = 2}) =>
    ConfirmedPlans.fromMap(
      Map<String, dynamic>.from(<Object?, Object?>{
        'plans': _planSetMap(blueprintVersion: blueprintVersion),
        'version': 3,
      }),
    );

/// Answers each plan from [replies]; a plan without a reply never finishes.
class FakeGenerationService extends GenerationService {
  FakeGenerationService(this.replies);

  final Map<String, Object> replies;
  final List<String> calls = [];

  @override
  Future<VariationImage> generate(String assetId, String planId) async {
    calls.add(planId);
    final reply = replies[planId];
    if (reply == null) return Completer<VariationImage>().future;
    if (reply is Exception) throw reply;
    return VariationImage.fromMap(
      Map<String, dynamic>.from(reply as Map<Object?, Object?>),
    );
  }

  @override
  Future<String> downloadUrl(String path) =>
      Future.error(StateError('no storage in tests'));
}

/// Answers each call with the next of [replies] (a reply map or an exception);
/// with no replies left, the call never finishes.
class FakeRenderService extends RenderService {
  FakeRenderService([List<Object>? replies]) : replies = replies ?? [];

  final List<Object> replies;
  final List<(String, SlideStyle, SlidePosition)> calls = [];

  @override
  Future<SlideRender> render(
    String assetId,
    String runId, {
    SlideStyle style = SlideStyle.outlined,
    SlidePosition position = SlidePosition.reference,
  }) async {
    calls.add((runId, style, position));
    if (replies.isEmpty) return Completer<SlideRender>().future;
    final reply = replies.removeAt(0);
    if (reply is Exception) throw reply;
    return SlideRender.fromMap(
      Map<String, dynamic>.from(reply as Map<Object?, Object?>),
    );
  }
}

/// Tall enough that both plan cards are built without scrolling.
void tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 7000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> pumpVariations(
  WidgetTester tester,
  FakeGenerationService service, {
  FakeRenderService? renderService,
  SlideshowService? slideshowService,
  SlideExporter? exporter,
  bool startNow = true,
  ConfirmedPlans? plans,
  ValueChanged<List<String>>? onFixBlueprint,
}) async {
  tallScreen(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildJustPostTheme(),
      home: VariationsScreen(
        assetId: assetId,
        plans: plans ?? confirmedPlans(),
        blueprint: editor_test.blueprint(),
        service: service,
        renderService: renderService ?? FakeRenderService(),
        slideshowService: slideshowService,
        exporter: exporter,
        onFixBlueprint: onFixBlueprint,
        startNow: startNow,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  test('VariationImage reads the generate_variation reply', () {
    final created = VariationImage.fromMap(
      Map<String, dynamic>.from(generationReply()),
    );
    expect(created.created, isTrue);
    expect(created.passed, isTrue);
    expect((created.width, created.height), (704, 1536));
    expect(created.imagePath, endsWith('variations/gen-p1.png'));
    expect(created.plansVersion, 3);
    expect(created.checks.first.question, contains('Shot inside a car'));
    expect(created.checks.first.passed, isTrue);
    expect(created.checks.first.note, 'Dashboard visible.');

    final rejected = VariationImage.fromMap(
      Map<String, dynamic>.from(
        generationReply(status: 'rejected', inspect: false),
      ),
    );
    expect((rejected.created, rejected.passed), (true, false));
    expect(rejected.imagePath, isNull);
    expect(rejected.checks.last.passed, isFalse);
    expect(rejected.checks.first.note, isNull);

    final failed = VariationImage.fromMap(
      Map<String, dynamic>.from(generationReply(status: 'failed')),
    );
    expect(failed.created, isFalse);
    expect(failed.issues, ['The image is blank or a single color.']);
    expect(failed.imagePath, isNull);
  });

  testWidgets('every plan starts at once and shows its own outcome', (
    tester,
  ) async {
    final service = FakeGenerationService({
      'p1': generationReply(),
      'p2': generationReply(planId: 'p2', status: 'failed'),
    });
    await pumpVariations(tester, service);

    expect(service.calls, ['p1', 'p2']);
    expect(find.byKey(const Key('checks-note')), findsOneWidget);
    expect(find.text('PASSED CHECKS'), findsOneWidget);
    expect(find.text('42 s · gpt-image-test'), findsOneWidget);
    expect(find.text('Hijab color: warm cream'), findsOneWidget);
    expect(find.text('POV: your lock screen teaches you'), findsOneWidget);
    expect(
      find.text('• The image is blank or a single color.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('retry-p2')), findsOneWidget);
    expect(find.byKey(const Key('retry-p1')), findsNothing);
  });

  testWidgets('try again asks for that plan only', (tester) async {
    final service = FakeGenerationService({
      'p1': generationReply(),
      'p2': const GenerationException("You've reached today's image limit."),
    });
    await pumpVariations(tester, service);
    expect(find.text("• You've reached today's image limit."), findsOneWidget);

    service.replies['p2'] = generationReply(planId: 'p2');
    await tester.tap(find.byKey(const Key('retry-p2')));
    await tester.pump();
    await tester.pump();

    expect(service.calls, ['p1', 'p2', 'p2']);
    expect(find.text('PASSED CHECKS'), findsNWidgets(2));
  });

  testWidgets('a plan still running shows progress', (tester) async {
    final service = FakeGenerationService({'p1': generationReply()});
    await pumpVariations(tester, service);
    expect(find.byKey(const Key('variation-creating')), findsOneWidget);
  });

  testWidgets('an image that did not pass gives reasons and no image', (
    tester,
  ) async {
    final renders = FakeRenderService();
    final service = FakeGenerationService({
      'p1': generationReply(status: 'rejected', inspect: false),
      'p2': generationReply(planId: 'p2', status: 'unverified', inspect: false),
    });
    await pumpVariations(tester, service, renderService: renders);

    expect(find.text("This image didn't pass"), findsOneWidget);
    expect(
      find.text('• Not allowed: Showing the face clearly'),
      findsOneWidget,
    );
    expect(find.text("We couldn't check this image"), findsOneWidget);
    expect(find.byKey(const Key('retry-p1')), findsOneWidget);
    expect(find.byKey(const Key('retry-p2')), findsOneWidget);
    expect(find.byKey(const Key('plain-image-p1')), findsNothing);
    expect(find.byKey(const Key('style-p1')), findsNothing);
    expect(renders.calls, isEmpty);
  });

  testWidgets('inspection shows an image that did not pass, labelled', (
    tester,
  ) async {
    final renders = FakeRenderService();
    final service = FakeGenerationService({
      'p1': generationReply(status: 'rejected'),
    });
    await pumpVariations(tester, service, renderService: renders);

    expect(find.text("This image didn't pass"), findsOneWidget);
    expect(find.text("DIDN'T PASS"), findsOneWidget);
    expect(renders.calls, hasLength(1));
  });

  testWidgets('the checks are listed under the image', (tester) async {
    final service = FakeGenerationService({'p1': generationReply()});
    await pumpVariations(tester, service);

    await tester.tap(find.text('What was checked'));
    await tester.pump();

    expect(
      find.text('Is this still true? Shot inside a car — Yes'),
      findsOneWidget,
    );
    expect(
      find.text("Checker's note (unchecked): Dashboard visible."),
      findsOneWidget,
    );
  });

  testWidgets('nothing starts until asked when startNow is off', (
    tester,
  ) async {
    final service = FakeGenerationService({});
    await pumpVariations(tester, service, startNow: false);
    expect(service.calls, isEmpty);
    expect(find.text('Waiting to start…'), findsNWidgets(2));
  });

  group('Create images on the Plans screen', () {
    PlanRun run({ConfirmedPlans? confirmed, int blueprintVersion = 2}) =>
        PlanRun.fromMap(
          Map<String, dynamic>.from(<Object?, Object?>{
            'assetId': assetId,
            'runId': 'plan1',
            'status': 'failed',
            'count': 2,
            'draft': null,
            'blueprintVersion': blueprintVersion,
            'confirmed': confirmed == null
                ? null
                : <Object?, Object?>{
                    'plans': confirmed.plans.toMap(),
                    'version': confirmed.version,
                  },
            'rawExposed': false,
            'attempts': const [],
          }),
        );

    Future<void> pumpPlans(
      WidgetTester tester,
      PlanRun run, {
      bool inspect = true,
    }) async {
      tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJustPostTheme(),
          home: PlansScreen(
            run: run,
            blueprint: editor_test.blueprint(),
            service: PlanService(),
            generationService: FakeGenerationService({}),
            showInspection: inspect,
          ),
        ),
      );
    }

    testWidgets('is offered outside inspection builds too', (tester) async {
      await pumpPlans(tester, run(confirmed: confirmedPlans()), inspect: false);
      expect(find.byKey(const Key('create-images-button')), findsOneWidget);
    });

    testWidgets('needs confirmed plans', (tester) async {
      await pumpPlans(tester, run());
      expect(find.text('Save the plans to create images.'), findsOneWidget);
    });

    testWidgets('refuses plans for an earlier blueprint', (tester) async {
      await pumpPlans(
        tester,
        run(confirmed: confirmedPlans(), blueprintVersion: 3),
      );
      expect(
        find.text(
          'These plans are for an earlier blueprint. Plan again first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('opens the Variations screen with confirmed plans', (
      tester,
    ) async {
      await pumpPlans(tester, run(confirmed: confirmedPlans()));
      expect(find.byKey(const Key('image-ready')), findsOneWidget);

      await tester.tap(find.byKey(const Key('create-images-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('variations-screen')), findsOneWidget);
    });
  });
}
