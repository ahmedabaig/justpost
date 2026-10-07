import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../create/model_run_widgets.dart';

/// How far a reference got, as reported by `list_slideshows`.
enum SlideshowStage {
  reference('reference', 'Uploaded'),
  analysis('analysis', 'Analyzed'),
  blueprint('blueprint', 'Blueprint saved'),
  plans('plans', 'Plans saved'),
  slides('slides', 'Slides made'),
  set('set', 'Set saved');

  const SlideshowStage(this.value, this.label);

  final String value;
  final String label;

  static SlideshowStage from(Object? value) => SlideshowStage.values.firstWhere(
    (stage) => stage.value == value,
    orElse: () => reference,
  );
}

/// One reference in the Library.
@immutable
class SlideshowSummary {
  const SlideshowSummary({
    required this.assetId,
    required this.createdAt,
    required this.updatedAt,
    required this.referencePath,
    required this.stage,
    required this.passedSlides,
    required this.setSize,
  });

  factory SlideshowSummary.fromMap(Map<String, dynamic> map) =>
      SlideshowSummary(
        assetId: map['assetId'] as String,
        createdAt: DateTime.tryParse(map['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(map['updatedAt'] as String? ?? ''),
        referencePath: map['referencePath'] as String?,
        stage: SlideshowStage.from(map['stage']),
        passedSlides: (map['passedSlides'] as num?)?.toInt() ?? 0,
        setSize: (map['setSize'] as num?)?.toInt() ?? 0,
      );

  final String assetId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? referencePath;
  final SlideshowStage stage;
  final int passedSlides;
  final int setSize;
}

/// A slide whose image passed its checks, drawn with its plan's text.
@immutable
class SetSlide {
  const SetSlide({
    required this.planId,
    required this.imagePath,
    this.number,
    this.title,
    this.text,
    this.width,
    this.height,
  });

  factory SetSlide.fromMap(Map<String, dynamic> map) => SetSlide(
    planId: map['planId'] as String,
    imagePath: map['imagePath'] as String,
    number: (map['number'] as num?)?.toInt(),
    title: map['title'] as String?,
    text: map['text'] as String?,
    width: (map['width'] as num?)?.toInt(),
    height: (map['height'] as num?)?.toInt(),
  );

  static List<SetSlide> listFrom(Object? value) => [
    for (final slide in value as List? ?? const [])
      if (slide is Map) SetSlide.fromMap(callableMap(slide)),
  ];

  final String planId;
  final String imagePath;

  /// The plan's 1-based place; null when the plans have changed since.
  final int? number;
  final String? title;
  final String? text;
  final int? width;
  final int? height;
}

/// A saved final set: the slides in the order they're exported.
@immutable
class FinalSet {
  const FinalSet({required this.version, required this.slides});

  factory FinalSet.fromMap(Map<String, dynamic> map) => FinalSet(
    version: (map['version'] as num?)?.toInt() ?? 1,
    slides: SetSlide.listFrom(map['slides']),
  );

  final int version;
  final List<SetSlide> slides;
}

/// One reference with its saved set and current passed slides, all checked
/// again by the server.
@immutable
class Slideshow {
  const Slideshow({
    required this.assetId,
    required this.referencePath,
    required this.finalSet,
    required this.passedSlides,
  });

  factory Slideshow.fromMap(Map<String, dynamic> map) => Slideshow(
    assetId: map['assetId'] as String,
    referencePath: map['referencePath'] as String?,
    finalSet: map['finalSet'] is Map
        ? FinalSet.fromMap(callableMap(map['finalSet']))
        : null,
    passedSlides: SetSlide.listFrom(map['passedSlides']),
  );

  final String assetId;
  final String? referencePath;
  final FinalSet? finalSet;

  /// In plan order. Empty when the plans changed since the slides were made.
  final List<SetSlide> passedSlides;
}

/// A failure the user can act on, with a message safe to show on screen.
class SlideshowException implements Exception {
  const SlideshowException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Saves final sets and loads the Library through Cloud Functions.
class SlideshowService {
  static const _maxSlideBytes = 20 * 1024 * 1024;

  /// Empty before the first upload, when there's no account yet.
  Future<List<SlideshowSummary>> list() async {
    if (FirebaseAuth.instance.currentUser == null) return const [];
    final data = await _call('list_slideshows', const {});
    return [
      for (final summary in data['slideshows'] as List? ?? const [])
        if (summary is Map) SlideshowSummary.fromMap(callableMap(summary)),
    ];
  }

  Future<Slideshow> get(String assetId) async =>
      Slideshow.fromMap(await _call('get_slideshow', {'assetId': assetId}));

  Future<FinalSet> saveSet(String assetId, List<String> planIds) async {
    final data = await _call('save_final_set', {
      'assetId': assetId,
      'planIds': planIds,
    });
    return FinalSet.fromMap(callableMap(data['finalSet']));
  }

  Future<String> downloadUrl(String path) =>
      FirebaseStorage.instance.ref(path).getDownloadURL();

  /// The slide's PNG, exactly as previewed.
  Future<Uint8List> download(String path) async {
    final bytes = await FirebaseStorage.instance
        .ref(path)
        .getData(_maxSlideBytes);
    if (bytes == null) {
      throw const SlideshowException('A slide could not be downloaded.');
    }
    return bytes;
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(
            name,
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call<Map<String, dynamic>>(data);
      return callableMap(result.data);
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: $name failed — ${error.code}');
      throw SlideshowException(_message(error));
    }
  }

  static String _message(FirebaseFunctionsException error) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'invalid-argument' ||
      'not-found' ||
      'failed-precondition' => error.message ?? 'That didn\'t work.',
      'deadline-exceeded' => 'The server took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => 'Something went wrong. Please try again.',
    };
  }
}

/// Saves slides to the photo library or hands them to the share sheet.
class SlideExporter {
  /// Saves the PNGs in order. Throws [SlideshowException] when Photos access
  /// is refused or the save fails.
  Future<void> saveToPhotos(List<Uint8List> slides) async {
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        throw const SlideshowException(_accessMessage);
      }
      for (final (index, slide) in slides.indexed) {
        await Gal.putImageBytes(slide, name: 'justpost-${index + 1}');
      }
    } on GalException catch (error) {
      debugPrint('JustPost: saving to Photos failed — ${error.type.name}');
      throw SlideshowException(switch (error.type) {
        GalExceptionType.accessDenied => _accessMessage,
        GalExceptionType.notEnoughSpace =>
          'There isn\'t enough space on this phone.',
        _ => 'Saving to Photos failed. Please try again.',
      });
    }
  }

  /// Opens the share sheet with the PNGs in order. [origin] anchors the
  /// popover on iPad.
  Future<void> share(List<Uint8List> slides, {Rect? origin}) async {
    final names = [
      for (var i = 1; i <= slides.length; i++) 'justpost-slide-$i.png',
    ];
    await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final (index, slide) in slides.indexed)
            XFile.fromData(slide, mimeType: 'image/png', name: names[index]),
        ],
        fileNameOverrides: names,
        sharePositionOrigin: origin,
      ),
    );
  }

  static const _accessMessage =
      'JustPost can\'t add to your photos. Turn on access in Settings > '
      'JustPost > Photos.';
}
