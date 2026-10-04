import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

enum VariationStatus { analyzing, generating, done, failed }

class VariationSlide {
  const VariationSlide({
    required this.slideId,
    required this.outputPath,
    required this.edited,
    required this.fallbackToOriginal,
    required this.skipReason,
  });

  factory VariationSlide.fromMap(Map<String, dynamic> map) => VariationSlide(
    slideId: map['slideId'] as String,
    outputPath: map['outputPath'] as String,
    edited: map['edited'] as bool? ?? false,
    fallbackToOriginal: map['fallbackToOriginal'] as bool?,
    skipReason: map['skipReason'] as String?,
  );

  final String slideId;
  final String outputPath;

  /// True only when the generated image passed verification and shipped.
  final bool edited;
  final bool? fallbackToOriginal;
  final String? skipReason;

  /// Why the original was kept, or null when the slide was edited.
  String? get keptOriginalReason {
    if (edited) return null;
    if (fallbackToOriginal == true) {
      return 'The edit changed protected content, so the original was kept.';
    }
    return skipReason ?? 'No safe edit was available for this slide.';
  }
}

class VariationJob {
  const VariationJob({
    required this.status,
    required this.slideCount,
    required this.completedSlides,
    required this.slides,
    required this.error,
  });

  factory VariationJob.fromMap(Map<String, dynamic> map) => VariationJob(
    status:
        VariationStatus.values.asNameMap()[map['status']] ??
        VariationStatus.analyzing,
    slideCount: map['slideCount'] as int? ?? 0,
    completedSlides: map['completedSlides'] as int? ?? 0,
    slides: [
      for (final slide in map['slides'] as List<dynamic>? ?? const [])
        VariationSlide.fromMap(Map<String, dynamic>.from(slide as Map)),
    ],
    error: map['error'] as String?,
  );

  final VariationStatus status;
  final int slideCount;
  final int completedSlides;
  final List<VariationSlide> slides;
  final String? error;
}

/// Uploads a slideshow, starts the `create_variation` Cloud Function, and
/// exposes the job's Firestore document as it progresses.
class VariationService {
  VariationService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    FirebaseFunctions? functions,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _firestore = firestore ?? FirebaseFirestore.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;

  Future<String> _ensureSignedIn() async {
    final current = _auth.currentUser;
    if (current != null) return current.uid;
    final credential = await _auth.signInAnonymously();
    return credential.user!.uid;
  }

  /// Uploads [slides] in order and returns the new job id.
  Future<String> upload(
    List<XFile> slides, {
    void Function(int uploaded, int total)? onProgress,
  }) async {
    final uid = await _ensureSignedIn();
    final jobId = _firestore.collection('jobs').doc().id;
    for (var index = 0; index < slides.length; index++) {
      final file = slides[index];
      final extension = _extensionFor(file.path);
      final name = 'slide${(index + 1).toString().padLeft(2, '0')}.$extension';
      await _storage
          .ref('jobs/$uid/$jobId/input/$name')
          .putFile(
            File(file.path),
            SettableMetadata(contentType: _contentTypes[extension]),
          );
      onProgress?.call(index + 1, slides.length);
    }
    return jobId;
  }

  /// Runs the pipeline. Completes when the function returns; progress and
  /// results arrive through [watch], which survives a dropped connection.
  Future<void> run(String jobId) {
    return _functions
        .httpsCallable(
          'create_variation',
          options: HttpsCallableOptions(timeout: const Duration(minutes: 30)),
        )
        .call<void>({'jobId': jobId});
  }

  Stream<VariationJob?> watch(String jobId) {
    return _firestore.collection('jobs').doc(jobId).snapshots().map((doc) {
      final data = doc.data();
      return data == null ? null : VariationJob.fromMap(data);
    });
  }

  Future<String> downloadUrl(String storagePath) =>
      _storage.ref(storagePath).getDownloadURL();

  static const _contentTypes = {
    'jpg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };

  static String _extensionFor(String path) {
    final extension = path.split('.').last.toLowerCase();
    if (extension == 'jpeg') return 'jpg';
    if (!_contentTypes.containsKey(extension)) {
      throw UnsupportedError('Unsupported slide format: .$extension');
    }
    return extension;
  }
}
