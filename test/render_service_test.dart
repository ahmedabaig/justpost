import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/plan_service.dart';
import 'package:just_post/features/create/render_service.dart';

import 'generation_service_test.dart' as gen;

Map<Object?, Object?> renderReply({
  String status = 'rendered',
  String style = 'outlined',
  String position = 'reference',
  bool hasText = true,
  bool exposed = true,
  List<String> issues = const [],
}) => {
  'assetId': gen.assetId,
  'planId': 'p1',
  'runId': 'gen-p1',
  'renderId': 'render-$style-$position',
  'status': status,
  'issues': issues,
  'layout': <Object?, Object?>{
    'schemaVersion': 1,
    'style': style,
    'position': position,
    'align': 'center',
    'box': <Object?, Object?>{'x': 0.1, 'y': 0.55, 'w': 0.8, 'h': 0.18},
  },
  'hasText': hasText,
  'fontSizePx': hasText ? 56 : null,
  'lines': hasText ? ['POV: your lock', 'screen teaches you'] : <String>[],
  'width': 704,
  'height': 1536,
  'imageExposed': exposed,
  'imagePath': status == 'rendered' && exposed
      ? 'uploads/u/${gen.assetId}/slides/render-$style-$position.png'
      : null,
};

/// Only plan p1, with the image already scripted to arrive.
Future<gen.FakeRenderService> _pumpOne(
  WidgetTester tester,
  List<Object> renders, {
  ConfirmedPlans? plans,
}) async {
  final renderService = gen.FakeRenderService(renders);
  await gen.pumpVariations(
    tester,
    gen.FakeGenerationService({
      'p1': gen.generationReply(),
      'p2': gen.generationReply(planId: 'p2', status: 'failed'),
    }),
    renderService: renderService,
    plans: plans,
  );
  return renderService;
}

void main() {
  test('SlideRender reads the render_slide reply', () {
    final slide = SlideRender.fromMap(
      Map<String, dynamic>.from(
        renderReply(style: 'dark_box', position: 'top'),
      ),
    );
    expect(slide.rendered, isTrue);
    expect(slide.style, SlideStyle.darkBox);
    expect(slide.position, SlidePosition.top);
    expect(slide.lines, hasLength(2));
    expect(slide.imagePath, endsWith('slides/render-dark_box-top.png'));

    final failed = SlideRender.fromMap(
      Map<String, dynamic>.from(
        renderReply(status: 'failed', issues: ["The text doesn't fit."]),
      ),
    );
    expect(failed.rendered, isFalse);
    expect(failed.imagePath, isNull);
  });

  test('styles and positions match the server values', () {
    expect(SlideStyle.values.map((style) => style.value), [
      'outlined',
      'white_box',
      'dark_box',
    ]);
    expect(SlidePosition.values.map((position) => position.value), [
      'reference',
      'top',
      'middle',
      'bottom',
    ]);
    expect(SlideStyle.from('unknown'), SlideStyle.outlined);
  });

  testWidgets('a created image gets its text drawn with the default layout', (
    tester,
  ) async {
    final renders = await _pumpOne(tester, [renderReply()]);

    expect(renders.calls, [
      ('gen-p1', SlideStyle.outlined, SlidePosition.reference),
    ]);
    expect(find.byKey(const Key('slide-image-p1')), findsOneWidget);
    expect(find.byKey(const Key('style-p1')), findsOneWidget);
    expect(find.text('Position: As in reference'), findsOneWidget);
    expect(find.text('Show without text'), findsOneWidget);
  });

  testWidgets('a slide moved off the subject shows its new position', (
    tester,
  ) async {
    await _pumpOne(tester, [renderReply(position: 'top')]);
    expect(find.text('Position: Top'), findsOneWidget);
  });

  testWidgets('the image without text is one tap away', (tester) async {
    await _pumpOne(tester, [renderReply()]);

    await tester.tap(find.byKey(const Key('plain-p1')));
    await tester.pump();
    expect(find.byKey(const Key('plain-image-p1')), findsOneWidget);
    expect(find.text('Show with text'), findsOneWidget);
  });

  testWidgets('changing the style draws the slide again', (tester) async {
    final renders = await _pumpOne(tester, [
      renderReply(),
      renderReply(style: 'white_box'),
    ]);

    await tester.tap(find.text('White box'));
    await tester.pump();
    await tester.pump();

    expect(renders.calls.last, (
      'gen-p1',
      SlideStyle.whiteBox,
      SlidePosition.reference,
    ));
    expect(find.byKey(const Key('render-error-p1')), findsNothing);
  });

  testWidgets('changing the position draws the slide again', (tester) async {
    final renders = await _pumpOne(tester, [
      renderReply(),
      renderReply(position: 'top'),
    ]);

    await tester.tap(find.byKey(const Key('position-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Top').last);
    await tester.pumpAndSettle();

    expect(renders.calls.last.$3, SlidePosition.top);
    expect(find.text('Position: Top'), findsOneWidget);
  });

  testWidgets('a failed redraw explains why and keeps the last choice', (
    tester,
  ) async {
    await _pumpOne(tester, [
      renderReply(),
      renderReply(
        status: 'failed',
        position: 'top',
        issues: [
          "The text doesn't fit in this position. Try another position.",
        ],
      ),
    ]);

    await tester.tap(find.byKey(const Key('position-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Top').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        "• The text doesn't fit in this position. Try another position.",
      ),
      findsOneWidget,
    );
    expect(find.text('Position: As in reference'), findsOneWidget);
    expect(find.byKey(const Key('slide-image-p1')), findsOneWidget);
  });

  testWidgets('server errors show on the card', (tester) async {
    await _pumpOne(tester, [
      const RenderException(
        'The plans changed since this image was made. Create the images again.',
      ),
    ]);
    expect(
      find.text(
        '• The plans changed since this image was made. Create the images '
        'again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a slide in progress shows a badge over the image', (
    tester,
  ) async {
    await _pumpOne(tester, []);
    expect(find.byKey(const Key('rendering-badge')), findsOneWidget);
  });

  testWidgets('plans without slide text have no text controls', (tester) async {
    final source = gen.confirmedPlans();
    final plans = ConfirmedPlans(
      version: source.version,
      plans: source.plans.withPlans([
        for (final plan in source.plans.plans)
          VariationPlan(
            id: plan.id,
            origin: plan.origin,
            title: plan.title,
            changes: plan.changes,
            copy: null,
          ),
      ]),
    );
    await _pumpOne(tester, [renderReply(hasText: false)], plans: plans);

    expect(find.byKey(const Key('style-p1')), findsNothing);
    expect(find.byKey(const Key('slide-image-p1')), findsOneWidget);
  });
}
