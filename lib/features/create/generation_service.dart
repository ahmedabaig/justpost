import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'model_run_widgets.dart';

/// One question the image was checked against, and how it was answered.
@immutable
class VariationCheck {
  const VariationCheck({
    required this.id,
    required this.question,
    required this.answer,
    required this.passed,
    this.note,
  });

  factory VariationCheck.fromMap(Map<String, dynamic> map) => VariationCheck(
    id: map['id'] as String? ?? '',
    question: map['question'] as String? ?? '',
    answer: map['answer'] as String? ?? 'unsure',
    passed: map['passed'] as bool?,
    note: map['note'] as String?,
  );

  final String id;
  final String question;

  /// `yes`, `no` or `unsure`.
  final String answer;

  /// Null for questions shown for information that don't decide the result.
  final bool? passed;

  /// The checking model's own words; only sent by inspection servers.
  final String? note;
}

/// The outcome of `generate_variation` for one plan: the image, and whether
/// it passed its check against the blueprint and the plan.
@immutable
class VariationImage {
  const VariationImage({
    required this.assetId,
    required this.planId,
    required this.runId,
    required this.status,
    required this.issues,
    required this.model,
    required this.latencyMs,
    required this.plansVersion,
    required this.width,
    required this.height,
    required this.imageExposed,
    required this.imagePath,
    this.checks = const [],
  });

  factory VariationImage.fromMap(Map<String, dynamic> map) => VariationImage(
    assetId: map['assetId'] as String,
    planId: map['planId'] as String,
    runId: map['runId'] as String,
    status: map['status'] as String? ?? 'failed',
    issues: callableStrings(map['issues']),
    model: map['model'] as String?,
    latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
    plansVersion: (map['plansVersion'] as num?)?.toInt() ?? 1,
    width: (map['width'] as num?)?.toInt(),
    height: (map['height'] as num?)?.toInt(),
    imageExposed: map['imageExposed'] == true,
    imagePath: map['imagePath'] as String?,
    checks: [
      for (final check in map['checks'] as List? ?? const [])
        if (check is Map) VariationCheck.fromMap(callableMap(check)),
    ],
  );

  final String assetId;
  final String planId;
  final String runId;

  /// `passed`, `rejected` (it didn't pass), `unverified` (it couldn't be
  /// checked), or `failed` when no image was made.
  final String status;

  /// Why the image failed, didn't pass or couldn't be checked.
  final List<String> issues;
  final String? model;
  final int latencyMs;

  /// The confirmed plans version the image was made from.
  final int plansVersion;
  final int? width;
  final int? height;
  final bool imageExposed;

  /// Set for passed images, and for others only when the server's inspection
  /// switch is on.
  final String? imagePath;
  final List<VariationCheck> checks;

  bool get passed => status == 'passed';

  /// An image file was made, whether or not it passed.
  bool get created => status != 'failed';
}

/// A failure the user can act on, with a message safe to show on screen.
class GenerationException implements Exception {
  const GenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Creates and checks one image per confirmed plan with `generate_variation`.
class GenerationService {
  Future<VariationImage> generate(String assetId, String planId) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(
            'generate_variation',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: 380),
            ),
          )
          .call<Map<String, dynamic>>({'assetId': assetId, 'planId': planId});
      return VariationImage.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: generate_variation failed — ${error.code}');
      throw GenerationException(_message(error));
    }
  }

  Future<String> downloadUrl(String path) =>
      FirebaseStorage.instance.ref(path).getDownloadURL();

  static String _message(FirebaseFunctionsException error) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'invalid-argument' ||
      'not-found' ||
      'failed-precondition' ||
      'resource-exhausted' => error.message ?? 'Creating the image failed.',
      'deadline-exceeded' =>
        'Creating the image took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => 'Creating the image failed. Please try again.',
    };
  }
}
