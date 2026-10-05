import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/blueprint_editor.dart';
import 'package:just_post/features/create/blueprint_service.dart';

BlueprintItem _item(
  String id,
  String text, {
  List<String> examples = const [],
}) => BlueprintItem(
  id: id,
  text: text,
  basis: const ['scene'],
  origin: 'ai',
  examples: examples,
);

Blueprint draft() => Blueprint(
  schemaVersion: 1,
  analysisRunId: 'run1',
  creativeFamily: 'ugc_car_selfie_hook',
  objective: 'Introduce a feature with a casual hook',
  sections: {
    BlueprintSection.mustKeep: [
      _item('req1', 'Face hidden by a graphic'),
      _item('req2', 'Shot inside a car'),
    ],
    BlueprintSection.niceToKeep: [_item('pref1', 'Natural daylight')],
    BlueprintSection.canVary: [
      _item('var1', 'Hijab color', examples: ['cream', 'black']),
    ],
    BlueprintSection.never: [_item('never1', 'Studio advertisement look')],
  },
  copyStrategy: const CopyStrategy(
    role: 'hook',
    primaryPattern: 'explain a concrete utility',
  ),
);

List<String> texts(BlueprintEditor editor, BlueprintSection section) => [
  for (final item in editor.blueprint.items(section)) item.text,
];

void main() {
  test('a fresh draft can be saved, and is clean right after saving', () {
    final editor = BlueprintEditor.fromDraft(draft());
    expect(editor.isDirty, isTrue);
    expect(editor.isEdited, isFalse);
    expect(editor.canSave, isTrue);

    final saved = editor.markSaved(editor.blueprint);
    expect(saved.hasSaved, isTrue);
    expect(saved.isDirty, isFalse);
    expect(saved.canSave, isFalse);

    final edited = saved.editText(
      BlueprintSection.mustKeep,
      'req2',
      'Inside a parked car',
    );
    expect(edited.isDirty, isTrue);
    expect(edited.canSave, isTrue);
  });

  test('editing an item changes its text and marks it as the user\'s', () {
    final editor = BlueprintEditor.fromDraft(draft())
        .editText(BlueprintSection.mustKeep, 'req1', '  Face stays covered  ');

    final item = editor.blueprint.items(BlueprintSection.mustKeep).first;
    expect(item.text, 'Face stays covered');
    expect(item.origin, 'user');
    expect(item.basis, ['scene']);
    expect(editor.isEdited, isTrue);
  });

  test('moving an item keeps its id, basis and examples', () {
    final editor = BlueprintEditor.fromDraft(draft())
        .move('req2', BlueprintSection.mustKeep, BlueprintSection.canVary);

    expect(texts(editor, BlueprintSection.mustKeep), [
      'Face hidden by a graphic',
    ]);
    expect(texts(editor, BlueprintSection.canVary), [
      'Hijab color',
      'Shot inside a car',
    ]);
    final moved = editor.blueprint.items(BlueprintSection.canVary).last;
    expect(moved.id, 'req2');
    expect(moved.basis, ['scene']);
    expect(
      editor.blueprint.toMap()['variationDimensions'][1],
      containsPair('name', 'Shot inside a car'),
    );
  });

  test('deleting and adding items', () {
    var editor = BlueprintEditor.fromDraft(draft())
        .delete(BlueprintSection.never, 'never1')
        .add(BlueprintSection.never, 'Showing the face')
        .add(BlueprintSection.niceToKeep, 'Arabic calligraphy feel');

    expect(texts(editor, BlueprintSection.never), ['Showing the face']);
    final added = editor.blueprint.items(BlueprintSection.niceToKeep).last;
    expect(added.id, 'u2');
    expect(added.origin, 'user');
    expect(added.basis, isEmpty);
    expect(editor.blueprint.items(BlueprintSection.never).single.id, 'u1');

    editor = editor.add(BlueprintSection.canVary, 'Drink');
    expect(editor.blueprint.items(BlueprintSection.canVary).last.id, 'u3');
  });

  test('the local check mirrors the server\'s limits for user edits', () {
    var editor = BlueprintEditor.fromDraft(draft())
        .delete(BlueprintSection.mustKeep, 'req1')
        .delete(BlueprintSection.mustKeep, 'req2');
    expect(editor.problems, ['Must keep needs at least 1 item.']);
    expect(editor.canSave, isFalse);

    editor = editor.add(BlueprintSection.mustKeep, 'Natural daylight');
    expect(
      editor.problems.single,
      contains('"Natural daylight" is already in'),
    );

    editor = editor
        .delete(BlueprintSection.niceToKeep, 'pref1')
        .delete(BlueprintSection.never, 'never1');
    expect(editor.problems, isEmpty, reason: 'Never may be empty for users');

    for (var i = 0; i < 12; i++) {
      editor = editor.add(BlueprintSection.canVary, 'Dimension $i');
    }
    expect(editor.problems, ['Can vary can have at most 12.']);
  });

  test(
    'copy strategy edits keep the role and allow clearing the secondary',
    () {
      final editor = BlueprintEditor.fromDraft(draft())
          .editCopy(primaryPattern: 'POV hook', secondaryPattern: 'daily value')
          .editCopy(secondaryPattern: '  ');

      final strategy = editor.blueprint.copyStrategy;
      expect(strategy.role, 'hook');
      expect(strategy.primaryPattern, 'POV hook');
      expect(strategy.secondaryPattern, isNull);

      expect(
        BlueprintEditor.fromDraft(draft())
            .editCopy(primaryPattern: ' ')
            .problems,
        ['The copy strategy needs a main pattern.'],
      );
    },
  );
}
