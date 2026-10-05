import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'blueprint_service.dart';

/// Immutable editing state for a blueprint draft. Every edit returns a new
/// editor. [problems] mirrors the server's checks for quick feedback; the
/// server's `save_blueprint` check is the one that counts.
@immutable
class BlueprintEditor {
  const BlueprintEditor._(this.blueprint, this._baseline, this.hasSaved);

  /// Starts from a draft that has not been saved yet.
  factory BlueprintEditor.fromDraft(Blueprint draft) =>
      BlueprintEditor._(draft, draft, false);

  final Blueprint blueprint;

  /// The draft this editor started from, or the version it last saved.
  final Blueprint _baseline;

  final bool hasSaved;

  /// True when the blueprint differs from the draft or the last save.
  bool get isEdited => _encode(blueprint) != _encode(_baseline);

  /// True when there is something to save: a draft that was never saved, or
  /// edits since the last save.
  bool get isDirty => !hasSaved || isEdited;

  bool get canSave => isDirty && problems.isEmpty;

  BlueprintEditor markSaved(Blueprint saved) =>
      BlueprintEditor._(saved, saved, true);

  BlueprintEditor editText(BlueprintSection section, String id, String text) {
    return _withSection(section, [
      for (final item in blueprint.items(section))
        if (item.id == id)
          item.copyWith(text: text.trim(), origin: 'user')
        else
          item,
    ]);
  }

  BlueprintEditor delete(BlueprintSection section, String id) {
    return _withSection(section, [
      for (final item in blueprint.items(section))
        if (item.id != id) item,
    ]);
  }

  BlueprintEditor move(String id, BlueprintSection from, BlueprintSection to) {
    if (from == to) return this;
    final moving = blueprint.items(from).where((item) => item.id == id);
    if (moving.isEmpty) return this;
    final sections = Map.of(blueprint.sections)
      ..[from] = [
        for (final item in blueprint.items(from))
          if (item.id != id) item,
      ]
      ..[to] = [...blueprint.items(to), moving.first];
    return BlueprintEditor._(
      blueprint.copyWith(sections: sections),
      _baseline,
      hasSaved,
    );
  }

  BlueprintEditor add(BlueprintSection section, String text) {
    final item = BlueprintItem(
      id: _nextUserId(),
      text: text.trim(),
      basis: const [],
      origin: 'user',
    );
    return _withSection(section, [...blueprint.items(section), item]);
  }

  BlueprintEditor editCopy({String? primaryPattern, String? secondaryPattern}) {
    final current = blueprint.copyStrategy;
    final secondary = secondaryPattern?.trim();
    return BlueprintEditor._(
      blueprint.copyWith(
        copyStrategy: CopyStrategy(
          role: current.role,
          primaryPattern: primaryPattern?.trim() ?? current.primaryPattern,
          secondaryPattern: secondaryPattern == null
              ? current.secondaryPattern
              : (secondary!.isEmpty ? null : secondary),
        ),
      ),
      _baseline,
      hasSaved,
    );
  }

  /// Reasons the blueprint can't be saved yet, in plain words.
  List<String> get problems {
    final found = <String>[];
    final seen = <String, String>{};
    for (final section in BlueprintSection.values) {
      final items = blueprint.items(section);
      if (items.length < section.minItems) {
        found.add('${section.label} needs at least ${section.minItems} item.');
      }
      if (items.length > section.maxItems) {
        found.add('${section.label} can have at most ${section.maxItems}.');
      }
      for (final item in items) {
        if (item.text.isEmpty) {
          found.add('${section.label} has an empty item.');
        } else if (item.text.length > section.maxTextLength) {
          found.add(
            '${section.label}: "${_preview(item.text)}" is longer than '
            '${section.maxTextLength} characters.',
          );
        }
        final key = _normalize(item.text);
        if (key.isEmpty) continue;
        final earlier = seen[key];
        if (earlier != null) {
          found.add('"${_preview(item.text)}" is already in $earlier.');
        } else {
          seen[key] = section.label;
        }
      }
    }
    if (blueprint.copyStrategy.primaryPattern.isEmpty) {
      found.add('The copy strategy needs a main pattern.');
    }
    return found;
  }

  BlueprintEditor _withSection(
    BlueprintSection section,
    List<BlueprintItem> items,
  ) {
    final sections = Map.of(blueprint.sections)..[section] = items;
    return BlueprintEditor._(
      blueprint.copyWith(sections: sections),
      _baseline,
      hasSaved,
    );
  }

  String _nextUserId() {
    var highest = 0;
    for (final items in blueprint.sections.values) {
      for (final item in items) {
        final match = RegExp(r'^u(\d+)$').firstMatch(item.id);
        if (match != null) {
          final number = int.parse(match.group(1)!);
          if (number > highest) highest = number;
        }
      }
    }
    return 'u${highest + 1}';
  }

  static String _encode(Blueprint blueprint) => jsonEncode(blueprint.toMap());

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static String _preview(String text) =>
      text.length <= 40 ? text : '${text.substring(0, 37)}...';
}
