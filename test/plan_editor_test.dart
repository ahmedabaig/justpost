import 'package:flutter_test/flutter_test.dart';

import 'package:just_post/features/create/blueprint_service.dart';
import 'package:just_post/features/create/plan_editor.dart';
import 'package:just_post/features/create/plan_service.dart';

import 'blueprint_editor_test.dart' as blueprint_test;

Blueprint blueprint({String role = 'hook'}) {
  final base = blueprint_test.draft();
  return Blueprint(
    schemaVersion: 1,
    analysisRunId: base.analysisRunId,
    creativeFamily: base.creativeFamily,
    objective: base.objective,
    sections: {
      ...base.sections,
      BlueprintSection.canVary: [
        const BlueprintItem(
          id: 'var1',
          text: 'Hijab color',
          basis: ['scene'],
          origin: 'ai',
        ),
        const BlueprintItem(
          id: 'var2',
          text: 'Drink',
          basis: ['scene'],
          origin: 'ai',
        ),
        const BlueprintItem(
          id: 'u1',
          text: 'Phone case',
          basis: [],
          origin: 'user',
        ),
      ],
    },
    copyStrategy: CopyStrategy(role: role, primaryPattern: 'how-to'),
  );
}

PlanSet draft() => const PlanSet(
  schemaVersion: 1,
  analysisRunId: 'run1',
  blueprintVersion: 2,
  plans: [
    VariationPlan(
      id: 'p1',
      origin: 'ai',
      title: 'Cozy coffee run',
      changes: [
        PlanChange(dimensionId: 'var1', value: 'warm cream'),
        PlanChange(dimensionId: 'var2', value: 'iced coffee'),
      ],
      copy: PlanCopy(text: 'POV: your lock screen teaches you', pattern: 'POV'),
    ),
  ],
);

PlanEditor editor() => PlanEditor.fromDraft(draft(), blueprint());

VariationPlan first(PlanEditor editor) => editor.plans.plans.first;

void main() {
  test('a fresh draft can be saved, and is clean right after saving', () {
    final fresh = editor();
    expect(fresh.isDirty, isTrue);
    expect(fresh.isEdited, isFalse);
    expect(fresh.canSave, isTrue);

    final saved = fresh.markSaved(fresh.plans);
    expect(saved.isDirty, isFalse);
    expect(saved.canSave, isFalse);
    expect(saved.editTitle('p1', 'Matcha morning').canSave, isTrue);
  });

  test('editing a change keeps its place and makes the plan the user\'s', () {
    final edited = editor()
        .editChange('p1', 1, value: '  matcha latte ')
        .editChange('p1', 0, dimensionId: 'u1');

    final plan = first(edited);
    expect(plan.origin, 'user');
    expect(plan.changes.map((c) => (c.dimensionId, c.value)), [
      ('u1', 'warm cream'),
      ('var2', 'matcha latte'),
    ]);
    expect(edited.isEdited, isTrue);
    expect(edited.problems, isEmpty);
  });

  test('only unused dimensions can be added, each once', () {
    var edited = editor();
    expect(edited.unusedDimensions(first(edited)).map((d) => d.id), ['u1']);

    edited = edited.addChange('p1', 'u1', 'clear glitter case');
    expect(edited.unusedDimensions(first(edited)), isEmpty);
    expect(first(edited).changes.last.value, 'clear glitter case');

    edited = edited.editChange('p1', 2, dimensionId: 'var1');
    expect(edited.problems, ['Cozy coffee run changes "Hijab color" twice.']);
  });

  test('removing every change is flagged', () {
    final edited = editor().removeChange('p1', 0).removeChange('p1', 0);
    expect(edited.problems, ['Cozy coffee run needs at least one change.']);
    expect(edited.canSave, isFalse);
  });

  test('added plans get user ids and start empty', () {
    var edited = editor().addPlan(' My idea ').addPlan('Another');
    final added = edited.plans.plans.sublist(1);
    expect(added.map((p) => p.id), ['u1', 'u2']);
    expect(added.first.title, 'My idea');
    expect(added.first.origin, 'user');
    expect(added.first.copy?.text, '');
    expect(
      edited.problems,
      containsAll([
        'My idea needs at least one change.',
        'My idea needs slide text.',
        'My idea needs a text style.',
      ]),
    );

    edited = edited.addPlan('Three').addPlan('Four').addPlan('Five');
    expect(edited.plans.plans, hasLength(5));
    expect(edited.canAddPlan, isFalse);
    expect(edited.addPlan('Six').plans.plans, hasLength(5));
  });

  test('deleting the last plan is flagged', () {
    final edited = editor().deletePlan('p1');
    expect(edited.plans.plans, isEmpty);
    expect(edited.problems, ['Keep at least one plan.']);
  });

  test('slide text follows the server\'s rules', () {
    expect(editor().editCopy('p1', text: 'x' * 151).problems, [
      'Cozy coffee run: the slide text is longer than 150 characters.',
    ]);
    expect(editor().editCopy('p1', text: 'One. Two. Three. Four.').problems, [
      'Cozy coffee run: keep the slide text to 3 sentences.',
    ]);
    expect(editor().editCopy('p1', text: 'Line one\nline two').problems, [
      'Cozy coffee run: keep the slide text to one line.',
    ]);
    expect(editor().editCopy('p1', pattern: ' ').problems, [
      'Cozy coffee run needs a text style.',
    ]);
  });

  test('plans carry no slide text when the copy role is none', () {
    final noText = PlanEditor.fromDraft(draft(), blueprint(role: 'none'));
    expect(noText.hasCopy, isFalse);
    expect(noText.addPlan('Quiet').plans.plans.last.copy, isNull);
  });

  test('the plan set keeps its blueprint version and run through edits', () {
    final map = editor().editTitle('p1', 'New').plans.toMap();
    expect(map['blueprintVersion'], 2);
    expect(map['analysisRunId'], 'run1');
    expect(map['plans'][0]['copy'], {
      'text': 'POV: your lock screen teaches you',
      'pattern': 'POV',
    });
  });
}
