import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'blueprint_service.dart';
import 'plan_service.dart';

/// Immutable editing state for a set of variation plans. Every edit returns a
/// new editor. [problems] mirrors the server's checks for quick feedback; the
/// server's `save_plans` check is the one that counts.
@immutable
class PlanEditor {
  const PlanEditor._(
    this.plans,
    this._baseline,
    this.hasSaved,
    this.dimensions,
    this.hasCopy,
  );

  /// Starts from a draft that has not been saved yet. [blueprint] is the
  /// confirmed blueprint the draft was written from.
  factory PlanEditor.fromDraft(PlanSet draft, Blueprint blueprint) =>
      PlanEditor._(
        draft,
        draft,
        false,
        blueprint.items(BlueprintSection.canVary),
        blueprint.copyStrategy.role != 'none',
      );

  final PlanSet plans;

  /// The draft this editor started from, or the version it last saved.
  final PlanSet _baseline;

  final bool hasSaved;

  /// The blueprint's "can vary" dimensions, the only ones a plan may change.
  final List<BlueprintItem> dimensions;

  /// Whether plans carry slide text; false when the copy role is `none`.
  final bool hasCopy;

  bool get isEdited => _encode(plans) != _encode(_baseline);

  bool get isDirty => !hasSaved || isEdited;

  bool get canSave => isDirty && problems.isEmpty;

  bool get canAddPlan => plans.plans.length < PlanLimits.maxPlans;

  String dimensionName(String id) {
    for (final dimension in dimensions) {
      if (dimension.id == id) return dimension.text;
    }
    return id;
  }

  /// Dimensions [plan] doesn't change yet.
  List<BlueprintItem> unusedDimensions(VariationPlan plan) {
    final used = {for (final change in plan.changes) change.dimensionId};
    return [
      for (final dimension in dimensions)
        if (!used.contains(dimension.id)) dimension,
    ];
  }

  PlanEditor markSaved(PlanSet saved) =>
      PlanEditor._(saved, saved, true, dimensions, hasCopy);

  PlanEditor editTitle(String planId, String title) =>
      _edit(planId, (plan) => plan.copyWith(title: title.trim()));

  PlanEditor editChange(
    String planId,
    int index, {
    String? dimensionId,
    String? value,
  }) => _edit(planId, (plan) {
    final changes = List.of(plan.changes);
    final current = changes[index];
    changes[index] = PlanChange(
      dimensionId: dimensionId ?? current.dimensionId,
      value: value?.trim() ?? current.value,
    );
    return plan.copyWith(changes: changes);
  });

  PlanEditor addChange(String planId, String dimensionId, String value) =>
      _edit(
        planId,
        (plan) => plan.copyWith(
          changes: [
            ...plan.changes,
            PlanChange(dimensionId: dimensionId, value: value.trim()),
          ],
        ),
      );

  PlanEditor removeChange(String planId, int index) => _edit(
    planId,
    (plan) => plan.copyWith(changes: List.of(plan.changes)..removeAt(index)),
  );

  PlanEditor editCopy(String planId, {String? text, String? pattern}) =>
      _edit(planId, (plan) {
        final current = plan.copy ?? const PlanCopy(text: '', pattern: '');
        return plan.copyWith(
          copy: PlanCopy(
            text: text?.trim() ?? current.text,
            pattern: pattern?.trim() ?? current.pattern,
          ),
        );
      });

  PlanEditor deletePlan(String planId) => _withPlans([
    for (final plan in plans.plans)
      if (plan.id != planId) plan,
  ]);

  PlanEditor addPlan(String title) {
    if (!canAddPlan) return this;
    final plan = VariationPlan(
      id: _nextUserId(),
      origin: 'user',
      title: title.trim(),
      changes: const [],
      copy: hasCopy ? const PlanCopy(text: '', pattern: '') : null,
    );
    return _withPlans([...plans.plans, plan]);
  }

  /// Reasons the plans can't be saved yet, in plain words.
  List<String> get problems {
    final found = <String>[];
    final count = plans.plans.length;
    if (count < PlanLimits.minPlans) found.add('Keep at least one plan.');
    if (count > PlanLimits.maxPlans) {
      found.add('Keep at most ${PlanLimits.maxPlans} plans.');
    }
    final known = {for (final dimension in dimensions) dimension.id};
    for (final (index, plan) in plans.plans.indexed) {
      final name = plan.title.isEmpty ? 'Plan ${index + 1}' : plan.title;
      if (plan.title.isEmpty) found.add('$name needs a title.');
      if (plan.title.length > PlanLimits.maxTitle) {
        found.add('$name: the title is too long.');
      }
      if (plan.changes.isEmpty) found.add('$name needs at least one change.');
      final used = <String>{};
      for (final change in plan.changes) {
        final dimension = dimensionName(change.dimensionId);
        if (!known.contains(change.dimensionId)) {
          found.add('$name changes something the blueprint doesn\'t allow.');
        } else if (!used.add(change.dimensionId)) {
          found.add('$name changes "$dimension" twice.');
        }
        if (change.value.isEmpty) {
          found.add('$name: "$dimension" needs a value.');
        } else if (change.value.length > PlanLimits.maxValue) {
          found.add(
            '$name: "$dimension" is longer than ${PlanLimits.maxValue} '
            'characters.',
          );
        }
      }
      final copy = plan.copy;
      if (hasCopy && copy == null) found.add('$name needs slide text.');
      if (copy != null) found.addAll(_copyProblems(name, copy));
    }
    return found;
  }

  List<String> _copyProblems(String name, PlanCopy copy) {
    final found = <String>[];
    if (copy.text.isEmpty) found.add('$name needs slide text.');
    if (copy.text.length > PlanLimits.maxHookText) {
      found.add(
        '$name: the slide text is longer than ${PlanLimits.maxHookText} '
        'characters.',
      );
    }
    if (copy.text.contains(RegExp(r'[\r\n]'))) {
      found.add('$name: keep the slide text to one line.');
    }
    final sentences = RegExp(r'[.!?]+(?=\s|$)').allMatches(copy.text).length;
    if (sentences > PlanLimits.maxHookSentences) {
      found.add(
        '$name: keep the slide text to ${PlanLimits.maxHookSentences} '
        'sentences.',
      );
    }
    if (copy.pattern.isEmpty) found.add('$name needs a text style.');
    if (copy.pattern.length > PlanLimits.maxPattern) {
      found.add('$name: the text style is too long.');
    }
    return found;
  }

  PlanEditor _edit(
    String planId,
    VariationPlan Function(VariationPlan plan) change,
  ) => _withPlans([
    for (final plan in plans.plans)
      if (plan.id == planId) change(plan) else plan,
  ]);

  PlanEditor _withPlans(List<VariationPlan> next) => PlanEditor._(
    plans.withPlans(next),
    _baseline,
    hasSaved,
    dimensions,
    hasCopy,
  );

  String _nextUserId() {
    var highest = 0;
    for (final plan in plans.plans) {
      final match = RegExp(r'^u(\d+)$').firstMatch(plan.id);
      if (match != null) {
        final number = int.parse(match.group(1)!);
        if (number > highest) highest = number;
      }
    }
    return 'u${highest + 1}';
  }

  static String _encode(PlanSet plans) => jsonEncode(plans.toMap());
}
