import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'model_run_widgets.dart';

/// The four editable parts of a blueprint, keyed as the server stores them.
/// Minimums and maximums mirror the server's limits for user edits.
enum BlueprintSection {
  mustKeep('requiredPrinciples', 'Must keep', minItems: 1, maxItems: 10),
  niceToKeep('preferredPrinciples', 'Nice to keep', minItems: 0, maxItems: 8),
  canVary('variationDimensions', 'Can vary', minItems: 1, maxItems: 12),
  never('forbiddenDrift', 'Never', minItems: 0, maxItems: 8);

  const BlueprintSection(
    this.key,
    this.label, {
    required this.minItems,
    required this.maxItems,
  });

  final String key;
  final String label;
  final int minItems;
  final int maxItems;

  /// "Can vary" items are dimensions with a name and examples; the rest are
  /// principles with text.
  bool get isDimension => this == BlueprintSection.canVary;

  int get maxTextLength => isDimension ? 80 : 200;
}

@immutable
class BlueprintItem {
  const BlueprintItem({
    required this.id,
    required this.text,
    required this.basis,
    required this.origin,
    this.examples = const [],
  });

  factory BlueprintItem.fromMap(Map<String, dynamic> map) {
    return BlueprintItem(
      id: map['id'] as String,
      text: (map['text'] ?? map['name']) as String,
      basis: callableStrings(map['basis']),
      origin: map['origin'] as String? ?? 'ai',
      examples: callableStrings(map['examples']),
    );
  }

  final String id;
  final String text;

  /// Analysis paths the item comes from; empty for items the user wrote.
  final List<String> basis;

  /// `ai` or `user`.
  final String origin;
  final List<String> examples;

  bool get fromUser => origin == 'user';

  BlueprintItem copyWith({String? text, String? origin}) => BlueprintItem(
    id: id,
    text: text ?? this.text,
    basis: basis,
    origin: origin ?? this.origin,
    examples: examples,
  );

  Map<String, dynamic> toMapFor(BlueprintSection section) => section.isDimension
      ? {
          'id': id,
          'name': text,
          'examples': examples,
          'basis': basis,
          'origin': origin,
        }
      : {'id': id, 'text': text, 'basis': basis, 'origin': origin};
}

@immutable
class CopyStrategy {
  const CopyStrategy({
    required this.role,
    required this.primaryPattern,
    this.secondaryPattern,
  });

  factory CopyStrategy.fromMap(Map<String, dynamic> map) => CopyStrategy(
    role: map['role'] as String? ?? 'none',
    primaryPattern: map['primaryPattern'] as String? ?? '',
    secondaryPattern: map['secondaryPattern'] as String?,
  );

  /// Set by the slide's text; not editable.
  final String role;
  final String primaryPattern;
  final String? secondaryPattern;

  Map<String, dynamic> toMap() => {
    'role': role,
    'primaryPattern': primaryPattern,
    'secondaryPattern': secondaryPattern,
  };
}

/// What must stay, what may change and what must never happen across
/// variations of one reference slide.
@immutable
class Blueprint {
  const Blueprint({
    required this.schemaVersion,
    required this.analysisRunId,
    required this.creativeFamily,
    required this.objective,
    required this.sections,
    required this.copyStrategy,
  });

  factory Blueprint.fromMap(Map<String, dynamic> map) {
    return Blueprint(
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      analysisRunId: map['analysisRunId'] as String,
      creativeFamily: map['creativeFamily'] as String? ?? '',
      objective: map['objective'] as String? ?? '',
      sections: {
        for (final section in BlueprintSection.values)
          section: [
            for (final item in (map[section.key] as List? ?? const []))
              BlueprintItem.fromMap(callableMap(item)),
          ],
      },
      copyStrategy: CopyStrategy.fromMap(callableMap(map['copyStrategy'])),
    );
  }

  final int schemaVersion;
  final String analysisRunId;
  final String creativeFamily;
  final String objective;
  final Map<BlueprintSection, List<BlueprintItem>> sections;
  final CopyStrategy copyStrategy;

  List<BlueprintItem> items(BlueprintSection section) =>
      sections[section] ?? const [];

  Blueprint copyWith({
    Map<BlueprintSection, List<BlueprintItem>>? sections,
    CopyStrategy? copyStrategy,
  }) => Blueprint(
    schemaVersion: schemaVersion,
    analysisRunId: analysisRunId,
    creativeFamily: creativeFamily,
    objective: objective,
    sections: sections ?? this.sections,
    copyStrategy: copyStrategy ?? this.copyStrategy,
  );

  Map<String, dynamic> toMap() => {
    'schemaVersion': schemaVersion,
    'analysisRunId': analysisRunId,
    'creativeFamily': creativeFamily,
    'objective': objective,
    for (final section in BlueprintSection.values)
      section.key: [for (final item in items(section)) item.toMapFor(section)],
    'copyStrategy': copyStrategy.toMap(),
  };
}

@immutable
class ConfirmedBlueprint {
  const ConfirmedBlueprint({required this.blueprint, required this.version});

  factory ConfirmedBlueprint.fromMap(Map<String, dynamic> map) =>
      ConfirmedBlueprint(
        blueprint: Blueprint.fromMap(callableMap(map['blueprint'])),
        version: (map['version'] as num?)?.toInt() ?? 1,
      );

  final Blueprint blueprint;
  final int version;
}

/// The outcome of `build_blueprint`: every attempt, the draft only if one
/// attempt passed the server's checks, and the currently confirmed blueprint.
@immutable
class BlueprintRun {
  const BlueprintRun({
    required this.assetId,
    required this.runId,
    required this.analysisRunId,
    required this.attempts,
    required this.rawExposed,
    required this.draft,
    required this.confirmed,
  });

  factory BlueprintRun.fromMap(Map<String, dynamic> map) {
    final draft = map['draft'];
    final confirmed = map['confirmed'];
    return BlueprintRun(
      assetId: map['assetId'] as String,
      runId: map['runId'] as String,
      analysisRunId: map['analysisRunId'] as String,
      attempts: ModelAttempt.listFrom(map['attempts']),
      rawExposed: map['rawExposed'] == true,
      draft: map['status'] == 'passed' && draft is Map
          ? Blueprint.fromMap(callableMap(draft))
          : null,
      confirmed: confirmed is Map
          ? ConfirmedBlueprint.fromMap(callableMap(confirmed))
          : null,
    );
  }

  final String assetId;
  final String runId;

  /// The analysis the slide currently has.
  final String analysisRunId;
  final List<ModelAttempt> attempts;
  final bool rawExposed;
  final Blueprint? draft;
  final ConfirmedBlueprint? confirmed;

  bool get passed => draft != null;
}

/// A failure the user can act on, with a message safe to show on screen.
class BlueprintException implements Exception {
  const BlueprintException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Drafts blueprints with `build_blueprint` and confirms edits with
/// `save_blueprint`.
class BlueprintService {
  HttpsCallable _callable(String name, Duration timeout) =>
      FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(name, options: HttpsCallableOptions(timeout: timeout));

  Future<BlueprintRun> build(String assetId) async {
    try {
      final result = await _callable(
        'build_blueprint',
        const Duration(seconds: 150),
      ).call<Map<String, dynamic>>({'assetId': assetId});
      return BlueprintRun.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: build_blueprint failed — ${error.code}');
      throw BlueprintException(_message(error, 'Building the blueprint'));
    }
  }

  Future<ConfirmedBlueprint> save(String assetId, Blueprint blueprint) async {
    try {
      final result =
          await _callable(
            'save_blueprint',
            const Duration(seconds: 30),
          ).call<Map<String, dynamic>>({
            'assetId': assetId,
            'blueprint': blueprint.toMap(),
          });
      return ConfirmedBlueprint.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: save_blueprint failed — ${error.code}');
      throw BlueprintException(_message(error, 'Saving the blueprint'));
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
