import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/analysis_result_view.dart';
import 'package:just_post/features/create/analysis_service.dart';
import 'package:just_post/theme/app_theme.dart';

const _raw = '```json\n{"schemaVersion": 1}\n```';

/// Shaped like the analyze_asset reply, with the untyped maps callables return.
Map<Object?, Object?> _reply({
  String status = 'passed',
  bool rawExposed = true,
}) {
  return <Object?, Object?>{
    'assetId': 'abcdefghij0123456789',
    'runId': 'run1',
    'status': status,
    'rawExposed': rawExposed,
    'analysis': status == 'passed'
        ? <Object?, Object?>{
            'schemaVersion': 1,
            'creativeType': 'ugc_hook_slide',
            'scene': <Object?, Object?>{
              'environment': 'car interior',
              'lighting': 'natural daylight',
              'background': 'street',
              'cameraStyle': 'casual selfie',
            },
            'subjects': [
              <Object?, Object?>{'description': 'woman in an olive hijab'},
            ],
            'visualDevices': [
              <Object?, Object?>{'description': 'pink heart over the face'},
            ],
            'copy': [
              <Object?, Object?>{
                'text': 'Here is how to do it',
                'role': 'hook',
                'region': <Object?, Object?>{
                  'x': 0.1,
                  'y': 0.6,
                  'w': 0.8,
                  'h': 0.1,
                },
              },
            ],
            'hookType': 'how-to',
            'mechanisms': ['specific utility'],
            'composition': <Object?, Object?>{
              'orientation': 'portrait',
              'visualHierarchy': ['subject', 'hook text'],
            },
            'aesthetic': ['UGC'],
            'centralElements': ['covered face'],
          }
        : null,
    'attempts': [
      <Object?, Object?>{
        'status': 'failed',
        'issues': ['The reply was not a single JSON object.'],
        'model': 'test-model',
        'latencyMs': 4200,
        'inputTokens': 1100,
        'outputTokens': 300,
        if (rawExposed) 'rawText': 'Sure! Here you go.',
      },
      <Object?, Object?>{
        'status': status,
        'issues': status == 'passed' ? [] : ['scene: Field required'],
        'model': 'test-model',
        'latencyMs': 3900,
        if (rawExposed) 'rawText': _raw,
      },
    ],
  };
}

AnalysisRun _run({String status = 'passed', bool rawExposed = true}) =>
    AnalysisRun.fromMap(
      Map<String, dynamic>.from(_reply(status: status, rawExposed: rawExposed)),
    );

Future<void> _pump(WidgetTester tester, AnalysisRun run, bool inspect) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildJustPostTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnalysisResultView(run: run, showInspection: inspect),
        ),
      ),
    ),
  );
}

void main() {
  test('AnalysisRun reads the analyze_asset reply', () {
    final run = _run();

    expect(run.passed, isTrue);
    expect(run.attempts, hasLength(2));
    expect(run.attempts.first.passed, isFalse);
    expect(run.attempts.first.issues.single, contains('JSON'));
    expect(run.attempts.first.inputTokens, 1100);
    expect(run.attempts.last.rawText, _raw);
    final analysis = run.analysis!;
    expect(analysis.creativeType, 'ugc_hook_slide');
    expect(analysis.scene, 'car interior · natural daylight · street');
    expect(analysis.slideText.single.role, 'hook');
    expect(analysis.visualHierarchy, ['subject', 'hook text']);
  });

  test('a failed run carries no analysis', () {
    final run = _run(status: 'failed');
    expect(run.passed, isFalse);
    expect(run.analysis, isNull);
    expect(run.attempts.last.issues, ['scene: Field required']);
  });

  testWidgets('inspection builds show the raw replies next to the check', (
    tester,
  ) async {
    await _pump(tester, _run(), true);

    expect(find.text('Check passed'), findsOneWidget);
    expect(find.byKey(const Key('checked-analysis')), findsOneWidget);
    expect(find.byKey(const Key('raw-output-panel')), findsOneWidget);
    expect(find.text('Sure! Here you go.'), findsOneWidget);
    expect(find.text(_raw), findsOneWidget);
  });

  testWidgets('the raw panel is hidden when the inspection flag is off', (
    tester,
  ) async {
    await _pump(tester, _run(), false);

    expect(find.text('Check passed'), findsOneWidget);
    expect(find.byKey(const Key('raw-output-panel')), findsNothing);
    expect(find.text('Sure! Here you go.'), findsNothing);
  });

  testWidgets('the raw panel is hidden when the server withholds raw text', (
    tester,
  ) async {
    await _pump(tester, _run(rawExposed: false), true);

    expect(find.byKey(const Key('raw-output-panel')), findsNothing);
  });

  testWidgets('a failed run shows the reasons and no analysis', (tester) async {
    await _pump(tester, _run(status: 'failed'), true);

    expect(find.text('Check failed'), findsOneWidget);
    expect(find.text('• scene: Field required'), findsOneWidget);
    expect(find.byKey(const Key('checked-analysis')), findsNothing);
  });
}
