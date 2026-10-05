import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'model_run_widgets.dart';

/// The outcome of `analyze_asset`: every attempt, plus the analysis only if
/// one attempt passed the server's checks.
@immutable
class AnalysisRun {
  const AnalysisRun({
    required this.assetId,
    required this.runId,
    required this.attempts,
    required this.rawExposed,
    required this.analysis,
  });

  factory AnalysisRun.fromMap(Map<String, dynamic> map) {
    final analysis = map['analysis'];
    return AnalysisRun(
      assetId: map['assetId'] as String,
      runId: map['runId'] as String,
      attempts: ModelAttempt.listFrom(map['attempts']),
      rawExposed: map['rawExposed'] == true,
      analysis: map['status'] == 'passed' && analysis is Map
          ? CheckedAnalysis.fromMap(callableMap(analysis))
          : null,
    );
  }

  final String assetId;
  final String runId;
  final List<ModelAttempt> attempts;
  final bool rawExposed;
  final CheckedAnalysis? analysis;

  bool get passed => analysis != null;
}

/// A creative analysis that passed the server's schema and policy checks.
@immutable
class CheckedAnalysis {
  const CheckedAnalysis({
    required this.creativeType,
    required this.hookType,
    required this.mechanisms,
    required this.scene,
    required this.cameraStyle,
    required this.subjects,
    required this.visualDevices,
    required this.slideText,
    required this.visualHierarchy,
    required this.aesthetic,
    required this.centralElements,
  });

  factory CheckedAnalysis.fromMap(Map<String, dynamic> map) {
    final scene = callableMap(map['scene']);
    final composition = callableMap(map['composition']);
    return CheckedAnalysis(
      creativeType: map['creativeType'] as String? ?? '',
      hookType: map['hookType'] as String?,
      mechanisms: callableStrings(map['mechanisms']),
      scene: [
        scene['environment'],
        scene['lighting'],
        scene['background'],
      ].whereType<String>().join(' · '),
      cameraStyle: scene['cameraStyle'] as String? ?? '',
      subjects: [
        for (final subject in (map['subjects'] as List? ?? const []))
          callableMap(subject)['description'] as String? ?? '',
      ],
      visualDevices: [
        for (final device in (map['visualDevices'] as List? ?? const []))
          callableMap(device)['description'] as String? ?? '',
      ],
      slideText: [
        for (final block in (map['copy'] as List? ?? const []))
          (
            role: callableMap(block)['role'] as String? ?? 'other',
            text: callableMap(block)['text'] as String? ?? '',
          ),
      ],
      visualHierarchy: callableStrings(composition['visualHierarchy']),
      aesthetic: callableStrings(map['aesthetic']),
      centralElements: callableStrings(map['centralElements']),
    );
  }

  final String creativeType;
  final String? hookType;
  final List<String> mechanisms;
  final String scene;
  final String cameraStyle;
  final List<String> subjects;
  final List<String> visualDevices;
  final List<({String role, String text})> slideText;
  final List<String> visualHierarchy;
  final List<String> aesthetic;
  final List<String> centralElements;
}

/// A failure the user can act on, with a message safe to show on screen.
class AnalysisException implements Exception {
  const AnalysisException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Asks the backend to describe the creative structure of an ingested slide.
class AnalysisService {
  Future<AnalysisRun> analyze(String assetId) async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(
            'analyze_asset',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: 150),
            ),
          );
      final result = await callable.call<Map<String, dynamic>>({
        'assetId': assetId,
      });
      return AnalysisRun.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: analyze_asset failed — ${error.code}');
      throw AnalysisException(_functionsMessage(error));
    }
  }

  static String _functionsMessage(FirebaseFunctionsException error) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'not-found' ||
      'failed-precondition' ||
      'resource-exhausted' => error.message ?? 'This slide cannot be analyzed.',
      'deadline-exceeded' => 'Analysis took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => 'Analysis failed. Please try again.',
    };
  }
}
