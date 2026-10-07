import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'model_run_widgets.dart';

/// Limits shared with the server's `check_plans`.
abstract final class PlanLimits {
  static const minPlans = 1;
  static const maxPlans = 5;
  static const maxTitle = 80;
  static const maxValue = 120;
  static const maxHookText = 150;
  static const maxHookSentences = 3;
  static const maxPattern = 80;
}

/// A new value for one of the blueprint's "can vary" dimensions.
@immutable
class PlanChange {
  const PlanChange({required this.dimensionId, required this.value});

  factory PlanChange.fromMap(Map<String, dynamic> map) => PlanChange(
    dimensionId: map['dimensionId'] as String,
    value: map['value'] as String? ?? '',
  );

  final String dimensionId;
  final String value;

  Map<String, dynamic> toMap() => {'dimensionId': dimensionId, 'value': value};
}

/// The slide text a plan will use, and the hook style it follows.
@immutable
class PlanCopy {
  const PlanCopy({required this.text, required this.pattern});

  factory PlanCopy.fromMap(Map<String, dynamic> map) => PlanCopy(
    text: map['text'] as String? ?? '',
    pattern: map['pattern'] as String? ?? '',
  );

  final String text;
  final String pattern;

  Map<String, dynamic> toMap() => {'text': text, 'pattern': pattern};
}

@immutable
class VariationPlan {
  const VariationPlan({
    required this.id,
    required this.origin,
    required this.title,
    required this.changes,
    required this.copy,
  });

  factory VariationPlan.fromMap(Map<String, dynamic> map) {
    final copy = map['copy'];
    return VariationPlan(
      id: map['id'] as String,
      origin: map['origin'] as String? ?? 'ai',
      title: map['title'] as String? ?? '',
      changes: [
        for (final change in (map['changes'] as List? ?? const []))
          PlanChange.fromMap(callableMap(change)),
      ],
      copy: copy is Map ? PlanCopy.fromMap(callableMap(copy)) : null,
    );
  }

  final String id;

  /// `ai` or `user`. Any edit makes a plan the user's.
  final String origin;
  final String title;
  final List<PlanChange> changes;

  /// Null when the blueprint's copy role is `none`.
  final PlanCopy? copy;

  bool get fromUser => origin == 'user';

  VariationPlan copyWith({
    String? title,
    List<PlanChange>? changes,
    PlanCopy? copy,
  }) => VariationPlan(
    id: id,
    origin: 'user',
    title: title ?? this.title,
    changes: changes ?? this.changes,
    copy: copy ?? this.copy,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'origin': origin,
    'title': title,
    'changes': [for (final change in changes) change.toMap()],
    'copy': copy?.toMap(),
  };
}

/// Plans written from one confirmed blueprint version.
@immutable
class PlanSet {
  const PlanSet({
    required this.schemaVersion,
    required this.analysisRunId,
    required this.blueprintVersion,
    required this.plans,
  });

  factory PlanSet.fromMap(Map<String, dynamic> map) => PlanSet(
    schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
    analysisRunId: map['analysisRunId'] as String,
    blueprintVersion: (map['blueprintVersion'] as num).toInt(),
    plans: [
      for (final plan in (map['plans'] as List? ?? const []))
        VariationPlan.fromMap(callableMap(plan)),
    ],
  );

  final int schemaVersion;
  final String analysisRunId;
  final int blueprintVersion;
  final List<VariationPlan> plans;

  PlanSet withPlans(List<VariationPlan> plans) => PlanSet(
    schemaVersion: schemaVersion,
    analysisRunId: analysisRunId,
    blueprintVersion: blueprintVersion,
    plans: plans,
  );

  Map<String, dynamic> toMap() => {
    'schemaVersion': schemaVersion,
    'analysisRunId': analysisRunId,
    'blueprintVersion': blueprintVersion,
    'plans': [for (final plan in plans) plan.toMap()],
  };
}

@immutable
class ConfirmedPlans {
  const ConfirmedPlans({required this.plans, required this.version});

  factory ConfirmedPlans.fromMap(Map<String, dynamic> map) => ConfirmedPlans(
    plans: PlanSet.fromMap(callableMap(map['plans'])),
    version: (map['version'] as num?)?.toInt() ?? 1,
  );

  final PlanSet plans;
  final int version;
}

/// The outcome of `plan_variations`: every attempt, the draft only if one
/// attempt passed the server's checks, and the currently confirmed plans.
@immutable
class PlanRun {
  const PlanRun({
    required this.assetId,
    required this.runId,
    required this.count,
    required this.blueprintVersion,
    required this.attempts,
    required this.rawExposed,
    required this.draft,
    required this.confirmed,
  });

  factory PlanRun.fromMap(Map<String, dynamic> map) {
    final draft = map['draft'];
    final confirmed = map['confirmed'];
    return PlanRun(
      assetId: map['assetId'] as String,
      runId: map['runId'] as String,
      count: (map['count'] as num?)?.toInt() ?? 1,
      blueprintVersion: (map['blueprintVersion'] as num).toInt(),
      attempts: ModelAttempt.listFrom(map['attempts']),
      rawExposed: map['rawExposed'] == true,
      draft: map['status'] == 'passed' && draft is Map
          ? PlanSet.fromMap(callableMap(draft))
          : null,
      confirmed: confirmed is Map
          ? ConfirmedPlans.fromMap(callableMap(confirmed))
          : null,
    );
  }

  final String assetId;
  final String runId;

  /// How many plans were asked for.
  final int count;

  /// The confirmed blueprint version the slide currently has.
  final int blueprintVersion;
  final List<ModelAttempt> attempts;
  final bool rawExposed;
  final PlanSet? draft;
  final ConfirmedPlans? confirmed;

  bool get passed => draft != null;
}

/// A failure the user can act on, with a message safe to show on screen.
class PlanException implements Exception {
  const PlanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Drafts variation plans with `plan_variations` and confirms edits with
/// `save_plans`.
class PlanService {
  HttpsCallable _callable(String name, Duration timeout) =>
      FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(name, options: HttpsCallableOptions(timeout: timeout));

  Future<PlanRun> plan(String assetId, int count) async {
    try {
      final result = await _callable(
        'plan_variations',
        const Duration(seconds: 150),
      ).call<Map<String, dynamic>>({'assetId': assetId, 'count': count});
      return PlanRun.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: plan_variations failed — ${error.code}');
      throw PlanException(_message(error, 'Planning the variations'));
    }
  }

  Future<ConfirmedPlans> save(String assetId, PlanSet plans) async {
    try {
      final result = await _callable('save_plans', const Duration(seconds: 30))
          .call<Map<String, dynamic>>({
            'assetId': assetId,
            'plans': plans.toMap(),
          });
      return ConfirmedPlans.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: save_plans failed — ${error.code}');
      throw PlanException(_message(error, 'Saving the plans'));
    }
  }

  static String _message(FirebaseFunctionsException error, String action) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'invalid-argument' ||
      'not-found' ||
      'failed-precondition' ||
      'resource-exhausted' => error.message ?? '$action failed.',
      'deadline-exceeded' => '$action took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => '$action failed. Please try again.',
    };
  }
}
