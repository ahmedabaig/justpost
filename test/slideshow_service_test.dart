import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/library/library_screen.dart';
import 'package:just_post/features/library/slideshow_screen.dart';
import 'package:just_post/features/library/slideshow_service.dart';
import 'package:just_post/theme/app_theme.dart';

import 'generation_service_test.dart' as gen;
import 'render_service_test.dart' as render;

String slidePath(String planId, [String render = 'r1']) =>
    'uploads/u/${gen.assetId}/slides/$planId-$render.png';

Map<String, Object?> slideMap(String planId, {int? number, String? render}) => {
  'planId': planId,
  'renderId': render ?? 'r1',
  'generationRunId': 'gen-$planId',
  'imagePath': slidePath(planId, render ?? 'r1'),
  'width': 704,
  'height': 1536,
  'number': ?number,
  if (number != null) 'title': 'Plan title $number',
  if (number != null) 'text': 'Text for plan $number',
};

/// A `get_slideshow` reply: passed slides p1 and p2, and an optional set.
Map<String, Object?> slideshowReply({
  List<String> passed = const ['p1', 'p2'],
  List<String>? saved,
}) => {
  'assetId': gen.assetId,
  'createdAt': '2026-10-03T10:00:00+00:00',
  'referencePath': 'uploads/u/${gen.assetId}/analysis.webp',
  'finalSet': saved == null
      ? null
      : {
          'version': 1,
          'savedAt': '2026-10-04T10:00:00+00:00',
          'slides': [
            for (final id in saved)
              slideMap(id, number: int.parse(id.substring(1))),
          ],
        },
  'passedSlides': [
    for (final id in passed) slideMap(id, number: int.parse(id.substring(1))),
  ],
};

class FakeSlideshowService extends SlideshowService {
  FakeSlideshowService({
    Object? slideshow,
    this.summaries = const [],
    this.saveError,
    this.listError,
  }) : slideshow = slideshow ?? slideshowReply();

  /// A reply map or an exception.
  Object slideshow;
  List<Map<String, Object?>> summaries;
  SlideshowException? saveError;
  SlideshowException? listError;

  final List<List<String>> saves = [];
  final List<String> downloads = [];
  int lists = 0;

  @override
  Future<List<SlideshowSummary>> list() async {
    lists++;
    if (listError case final error?) throw error;
    return [for (final map in summaries) SlideshowSummary.fromMap(map)];
  }

  @override
  Future<Slideshow> get(String assetId) async {
    final reply = slideshow;
    if (reply is Exception) throw reply;
    return Slideshow.fromMap(Map<String, dynamic>.from(reply as Map));
  }

  @override
  Future<FinalSet> saveSet(String assetId, List<String> planIds) async {
    saves.add(planIds);
    if (saveError case final error?) throw error;
    return FinalSet.fromMap({
      'version': saves.length,
      'slides': [for (final id in planIds) slideMap(id)],
    });
  }

  @override
  Future<String> downloadUrl(String path) =>
      Future.error(StateError('no storage in tests'));

  @override
  Future<Uint8List> download(String path) async {
    downloads.add(path);
    return Uint8List.fromList(path.codeUnits);
  }
}

class FakeExporter extends SlideExporter {
  FakeExporter({this.error});

  final SlideshowException? error;
  final List<List<String>> saved = [];
  final List<List<String>> shared = [];

  static List<String> _paths(List<Uint8List> files) => [
    for (final file in files) String.fromCharCodes(file),
  ];

  @override
  Future<void> saveToPhotos(List<Uint8List> slides) async {
    if (error case final error?) throw error;
    saved.add(_paths(slides));
  }

  @override
  Future<void> share(List<Uint8List> slides, {Rect? origin}) async {
    if (error case final error?) throw error;
    shared.add(_paths(slides));
  }
}

Future<void> pumpSlideshow(
  WidgetTester tester,
  FakeSlideshowService service, {
  FakeExporter? exporter,
}) async {
  gen.tallScreen(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildJustPostTheme(),
      home: SlideshowScreen(
        assetId: gen.assetId,
        service: service,
        exporter: exporter ?? FakeExporter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
  await tester.pump();
}

/// The plan IDs of the slide rows, top to bottom.
List<String> rowOrder(WidgetTester tester) {
  final rows = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('set-slide-'),
  );
  final keys = [
    for (final element in rows.evaluate())
      (
        (element.widget.key! as ValueKey<String>).value,
        tester.getTopLeft(find.byWidget(element.widget)).dy,
      ),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (key, _) in keys) key.substring('set-slide-'.length)];
}

void main() {
  test('the models read the get_slideshow and list_slideshows replies', () {
    final show = Slideshow.fromMap(
      Map<String, dynamic>.from(slideshowReply(saved: ['p2'])),
    );
    expect(show.passedSlides.map((s) => s.planId), ['p1', 'p2']);
    expect(show.passedSlides.first.title, 'Plan title 1');
    expect(show.finalSet?.slides.single.imagePath, slidePath('p2'));
    expect(
      Slideshow.fromMap(Map<String, dynamic>.from(slideshowReply())).finalSet,
      isNull,
    );

    final summary = SlideshowSummary.fromMap({
      'assetId': gen.assetId,
      'createdAt': '2026-10-03T10:00:00+00:00',
      'updatedAt': null,
      'referencePath': null,
      'stage': 'set',
      'passedSlides': 3,
      'setSize': 2,
    });
    expect(summary.stage, SlideshowStage.set);
    expect(summary.createdAt, DateTime.utc(2026, 10, 3, 10));
    expect(summary.updatedAt, isNull);
    expect(SlideshowStage.from('something new'), SlideshowStage.reference);
  });

  group('Slideshow screen', () {
    testWidgets('starts with every passed slide and saves them in order', (
      tester,
    ) async {
      final service = FakeSlideshowService();
      await pumpSlideshow(tester, service);

      expect(rowOrder(tester), ['p1', 'p2']);
      expect(find.byKey(const Key('save-photos')), findsNothing);

      await tapKey(tester, 'save-set');
      expect(service.saves, [
        ['p1', 'p2'],
      ]);
      expect(find.text('Set saved'), findsOneWidget);
      expect(find.byKey(const Key('save-photos')), findsOneWidget);
    });

    testWidgets('saves the slides ticked, in the order chosen', (tester) async {
      final service = FakeSlideshowService(
        slideshow: slideshowReply(passed: ['p1', 'p2', 'p3']),
      );
      await pumpSlideshow(tester, service);

      await tapKey(tester, 'up-p3');
      await tapKey(tester, 'up-p3');
      expect(rowOrder(tester), ['p3', 'p1', 'p2']);
      await tapKey(tester, 'include-p1');
      expect(find.text('Not in the set'), findsOneWidget);

      await tapKey(tester, 'save-set');
      expect(service.saves.single, ['p3', 'p2']);
    });

    testWidgets('needs at least one slide ticked', (tester) async {
      final service = FakeSlideshowService(
        slideshow: slideshowReply(passed: ['p1']),
      );
      await pumpSlideshow(tester, service);

      await tapKey(tester, 'include-p1');
      expect(find.byKey(const Key('set-empty')), findsOneWidget);
      await tapKey(tester, 'save-set');
      expect(service.saves, isEmpty);
    });

    testWidgets('shows why the set was refused', (tester) async {
      final service = FakeSlideshowService(
        saveError: const SlideshowException(
          'Plan 2 has no slide that passed its checks.',
        ),
      );
      await pumpSlideshow(tester, service);

      await tapKey(tester, 'save-set');
      expect(
        find.text('Plan 2 has no slide that passed its checks.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('save-photos')), findsNothing);
    });

    testWidgets('opens a saved set in its order, ready to export', (
      tester,
    ) async {
      final exporter = FakeExporter();
      final service = FakeSlideshowService(
        slideshow: slideshowReply(saved: ['p2', 'p1']),
      );
      await pumpSlideshow(tester, service, exporter: exporter);

      expect(rowOrder(tester), ['p2', 'p1']);
      expect(find.text('Set saved'), findsOneWidget);

      await tapKey(tester, 'save-photos');
      expect(exporter.saved.single, [slidePath('p2'), slidePath('p1')]);
      expect(find.text('Saved 2 slides to Photos.'), findsOneWidget);

      await tapKey(tester, 'share-set');
      expect(exporter.shared.single, [slidePath('p2'), slidePath('p1')]);
    });

    testWidgets('a changed set must be saved again before export', (
      tester,
    ) async {
      final service = FakeSlideshowService(
        slideshow: slideshowReply(saved: ['p1', 'p2']),
      );
      await pumpSlideshow(tester, service);

      await tapKey(tester, 'down-p1');
      expect(find.byKey(const Key('save-photos')), findsNothing);
      expect(find.byKey(const Key('set-changed')), findsOneWidget);

      await tapKey(tester, 'save-set');
      expect(service.saves.single, ['p2', 'p1']);
      expect(find.byKey(const Key('save-photos')), findsOneWidget);
    });

    testWidgets('a slide restyled since the save counts as a change', (
      tester,
    ) async {
      final reply = slideshowReply(saved: ['p1']);
      (reply['passedSlides']! as List)[0] = slideMap(
        'p1',
        number: 1,
        render: 'r2',
      );
      await pumpSlideshow(tester, FakeSlideshowService(slideshow: reply));

      expect(rowOrder(tester), ['p1', 'p2']);
      expect(find.text('Save set'), findsOneWidget);
      expect(find.byKey(const Key('set-changed')), findsOneWidget);
    });

    testWidgets('says how to allow Photos when access is refused', (
      tester,
    ) async {
      final exporter = FakeExporter(
        error: const SlideshowException(
          "JustPost can't add to your photos. Turn on access in Settings > "
          'JustPost > Photos.',
        ),
      );
      await pumpSlideshow(
        tester,
        FakeSlideshowService(slideshow: slideshowReply(saved: ['p1'])),
        exporter: exporter,
      );

      await tapKey(tester, 'save-photos');
      expect(find.byKey(const Key('export-error')), findsOneWidget);
      expect(find.textContaining('Settings > JustPost'), findsOneWidget);
    });

    testWidgets('shows a saved set read-only once the plans changed', (
      tester,
    ) async {
      final exporter = FakeExporter();
      await pumpSlideshow(
        tester,
        FakeSlideshowService(
          slideshow: slideshowReply(passed: [], saved: ['p1']),
        ),
        exporter: exporter,
      );

      expect(rowOrder(tester), ['p1']);
      expect(find.byKey(const Key('include-p1')), findsNothing);
      expect(find.byKey(const Key('save-set')), findsNothing);

      await tapKey(tester, 'save-photos');
      expect(exporter.saved.single, [slidePath('p1')]);
      expect(find.text('Saved 1 slide to Photos.'), findsOneWidget);
    });

    testWidgets('has nothing to export without passed slides', (tester) async {
      await pumpSlideshow(
        tester,
        FakeSlideshowService(slideshow: slideshowReply(passed: [])),
      );
      expect(find.byKey(const Key('slideshow-empty')), findsOneWidget);
      expect(find.byKey(const Key('save-photos')), findsNothing);
    });

    testWidgets('shows a loading error with a retry', (tester) async {
      final service = FakeSlideshowService(
        slideshow: const SlideshowException('This slideshow was not found.'),
      );
      await pumpSlideshow(tester, service);
      expect(find.text('This slideshow was not found.'), findsOneWidget);

      service.slideshow = slideshowReply();
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(rowOrder(tester), ['p1', 'p2']);
    });
  });

  group('Library', () {
    Map<String, Object?> summary(String id, {String stage = 'set'}) => {
      'assetId': id,
      'createdAt': '2026-10-03T10:00:00+00:00',
      'updatedAt': '2026-10-04T10:00:00+00:00',
      'referencePath': null,
      'stage': stage,
      'passedSlides': 3,
      'setSize': stage == 'set' ? 2 : 0,
    };

    Future<ValueNotifier<int>> pumpLibrary(
      WidgetTester tester,
      FakeSlideshowService service,
    ) async {
      final requests = ValueNotifier(0);
      addTearDown(requests.dispose);
      gen.tallScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildJustPostTheme(),
          home: Scaffold(
            body: LibraryScreen(
              service: service,
              exporter: FakeExporter(),
              refreshRequests: requests,
            ),
          ),
        ),
      );
      return requests;
    }

    testWidgets('loads only when the tab asks for it', (tester) async {
      final service = FakeSlideshowService(summaries: [summary('a1')]);
      final requests = await pumpLibrary(tester, service);
      expect(service.lists, 0);
      expect(find.byKey(const Key('library-empty')), findsOneWidget);

      requests.value++;
      await tester.pump();
      await tester.pump();
      expect(service.lists, 1);
      expect(find.byKey(const Key('library-a1')), findsOneWidget);
      expect(find.text('Set saved'), findsOneWidget);
      expect(find.text('2 slides in the set · 3 passed'), findsOneWidget);
      expect(
        find.text(formatDay(DateTime.utc(2026, 10, 4, 10))),
        findsOneWidget,
      );
    });

    testWidgets('shows the empty state with no references', (tester) async {
      final service = FakeSlideshowService();
      final requests = await pumpLibrary(tester, service);
      requests.value++;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('library-empty')), findsOneWidget);
    });

    testWidgets('shows a loading error', (tester) async {
      final service = FakeSlideshowService(
        listError: const SlideshowException(
          'The server is unavailable. Please try again.',
        ),
      );
      final requests = await pumpLibrary(tester, service);
      requests.value++;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('library-error')), findsOneWidget);
    });

    testWidgets('opens a reference and refreshes on the way back', (
      tester,
    ) async {
      final service = FakeSlideshowService(
        summaries: [summary('a1', stage: 'slides')],
        slideshow: slideshowReply(),
      );
      final requests = await pumpLibrary(tester, service);
      requests.value++;
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('library-a1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('slideshow-screen')), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('slideshow-screen')), findsNothing);
      expect(service.lists, 2);
    });
  });

  group('Review set on the Variations screen', () {
    testWidgets('opens the final set once a slide passed', (tester) async {
      final service = FakeSlideshowService();
      await gen.pumpVariations(
        tester,
        gen.FakeGenerationService({
          'p1': gen.generationReply(),
          'p2': gen.generationReply(planId: 'p2', status: 'failed'),
        }),
        renderService: gen.FakeRenderService([render.renderReply()]),
        slideshowService: service,
        exporter: FakeExporter(),
      );
      await tester.pump();

      final button = find.byKey(const Key('review-set'));
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('slideshow-screen')), findsOneWidget);
      expect(rowOrder(tester), ['p1', 'p2']);
    });

    testWidgets('is off while an image is still being made', (tester) async {
      await gen.pumpVariations(
        tester,
        gen.FakeGenerationService({'p1': gen.generationReply()}),
        renderService: gen.FakeRenderService([render.renderReply()]),
        slideshowService: FakeSlideshowService(),
      );
      await tester.pump();

      final button = find.byKey(const Key('review-set'));
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(find.byKey(const Key('slideshow-screen')), findsNothing);
    });
  });
}
