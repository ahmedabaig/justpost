import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/blueprint_screen.dart';
import 'package:just_post/features/create/blueprint_service.dart';
import 'package:just_post/theme/app_theme.dart';

const _raw = '{"schemaVersion": 1, "creativeFamily": "ugc_car_selfie_hook"}';

Map<Object?, Object?> _principle(String id, String text) => {
  'id': id,
  'text': text,
  'basis': ['scene'],
  'origin': 'ai',
};

/// Shaped like the server's blueprint, with the untyped maps callables return.
Map<Object?, Object?> _blueprintMap({String analysisRunId = 'run1'}) => {
  'schemaVersion': 1,
  'analysisRunId': analysisRunId,
  'creativeFamily': 'ugc_car_selfie_hook',
  'objective': 'Introduce a feature with a casual hook',
  'requiredPrinciples': [
    _principle('req1', 'Face hidden by a graphic'),
    _principle('req2', 'Shot inside a car'),
  ],
  'preferredPrinciples': [_principle('pref1', 'Natural daylight')],
  'variationDimensions': [
    <Object?, Object?>{
      'id': 'var1',
      'name': 'Hijab color',
      'examples': ['cream', 'black'],
      'basis': ['subjects.0.styling'],
      'origin': 'ai',
    },
  ],
  'forbiddenDrift': [_principle('never1', 'Studio advertisement look')],
  'copyStrategy': <Object?, Object?>{
    'role': 'hook',
    'primaryPattern': 'explain a concrete utility',
    'secondaryPattern': null,
  },
};

Map<Object?, Object?> _reply({
  String status = 'passed',
  bool rawExposed = true,
  Map<Object?, Object?>? confirmed,
}) => {
  'assetId': 'abcdefghij0123456789',
  'runId': 'bp1',
  'status': status,
  'analysisRunId': 'run2',
  'draft': status == 'passed' ? _blueprintMap(analysisRunId: 'run2') : null,
  'confirmed': confirmed,
  'rawExposed': rawExposed,
  'attempts': [
    <Object?, Object?>{
      'status': status,
      'issues': status == 'passed'
          ? []
          : ['requiredPrinciples: needs at least 3'],
      'model': 'test-model',
      'latencyMs': 5100,
      if (rawExposed) 'rawText': _raw,
    },
  ],
};

BlueprintRun _run({
  String status = 'passed',
  bool rawExposed = true,
  Map<Object?, Object?>? confirmed,
}) => BlueprintRun.fromMap(
  Map<String, dynamic>.from(
    _reply(status: status, rawExposed: rawExposed, confirmed: confirmed),
  ),
);

/// The screen's list; selectable text adds scrollables of its own.
final _page = find.byType(Scrollable).first;

Future<void> _pump(WidgetTester tester, BlueprintRun run, bool inspect) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildJustPostTheme(),
      home: BlueprintScreen(
        run: run,
        service: BlueprintService(),
        showInspection: inspect,
      ),
    ),
  );
}

void main() {
  test('Blueprint round-trips through toMap in the server\'s shape', () {
    final source = Map<String, dynamic>.from(_blueprintMap());
    final blueprint = Blueprint.fromMap(source);

    expect(blueprint.items(BlueprintSection.mustKeep), hasLength(2));
    expect(
      blueprint.items(BlueprintSection.canVary).single.text,
      'Hijab color',
    );
    expect(blueprint.items(BlueprintSection.canVary).single.examples, [
      'cream',
      'black',
    ]);

    final map = blueprint.toMap();
    expect(map['variationDimensions'], [
      {
        'id': 'var1',
        'name': 'Hijab color',
        'examples': ['cream', 'black'],
        'basis': ['subjects.0.styling'],
        'origin': 'ai',
      },
    ]);
    expect(map['requiredPrinciples'][0], {
      'id': 'req1',
      'text': 'Face hidden by a graphic',
      'basis': ['scene'],
      'origin': 'ai',
    });
    expect(map['copyStrategy'], {
      'role': 'hook',
      'primaryPattern': 'explain a concrete utility',
      'secondaryPattern': null,
    });
    expect(Blueprint.fromMap(map).toMap(), map);
  });

  test('BlueprintRun reads the build_blueprint reply', () {
    final run = _run(confirmed: {'blueprint': _blueprintMap(), 'version': 3});
    expect(run.passed, isTrue);
    expect(run.analysisRunId, 'run2');
    expect(run.draft!.analysisRunId, 'run2');
    expect(run.confirmed!.version, 3);
    expect(run.confirmed!.blueprint.analysisRunId, 'run1');
    expect(run.attempts.single.rawText, _raw);

    final failed = _run(status: 'failed');
    expect(failed.passed, isFalse);
    expect(failed.draft, isNull);
  });

  testWidgets('the screen shows the editable draft and the raw output', (
    tester,
  ) async {
    await _pump(tester, _run(), true);

    expect(find.text('Check passed'), findsOneWidget);
    expect(find.text('Face hidden by a graphic'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('section-never')),
      300,
      scrollable: _page,
    );
    expect(find.text('e.g. cream, black'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('raw-output-panel')),
      300,
      scrollable: _page,
    );
    expect(find.text(_raw), findsOneWidget);
  });

  testWidgets('the raw panel is hidden when the inspection flag is off', (
    tester,
  ) async {
    await _pump(tester, _run(), false);
    expect(find.byKey(const Key('raw-output-panel')), findsNothing);
    expect(find.text(_raw), findsNothing);
  });

  testWidgets('deleting an item from its menu updates the section', (
    tester,
  ) async {
    await _pump(tester, _run(), false);

    await tester.tap(find.byTooltip('Item options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Face hidden by a graphic'), findsNothing);
    expect(find.text('1/10'), findsOneWidget);
  });

  testWidgets('a stale confirmed blueprint is noted', (tester) async {
    await _pump(
      tester,
      _run(confirmed: {'blueprint': _blueprintMap(), 'version': 2}),
      false,
    );
    expect(find.text('Confirmed, version 2'), findsOneWidget);
    expect(
      find.text('Built from an earlier analysis of this slide.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed build shows the reasons and no editor', (tester) async {
    await _pump(tester, _run(status: 'failed'), true);
    expect(find.text('Check failed'), findsOneWidget);
    expect(find.text('• requiredPrinciples: needs at least 3'), findsOneWidget);
    expect(find.byKey(const Key('save-blueprint-button')), findsNothing);
  });
}
