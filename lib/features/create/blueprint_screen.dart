import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/build_flags.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import 'blueprint_editor.dart';
import 'blueprint_service.dart';
import 'create_steps.dart';
import 'model_run_widgets.dart';
import 'plan_service.dart';
import 'plans_screen.dart';

/// Shows a blueprint run, lets the user edit the draft, and saves the edited
/// version as the confirmed blueprint.
class BlueprintScreen extends StatefulWidget {
  const BlueprintScreen({
    super.key,
    required this.run,
    required this.service,
    this.planService,
    this.referencePath,
    this.showInspection = showAiInspection,
  });

  final BlueprintRun run;
  final BlueprintService service;
  final PlanService? planService;

  /// The slide's analysis copy, passed on to the plans and images.
  final String? referencePath;
  final bool showInspection;

  @override
  State<BlueprintScreen> createState() => _BlueprintScreenState();
}

class _BlueprintScreenState extends State<BlueprintScreen> {
  late BlueprintRun _run = widget.run;
  late BlueprintEditor? _editor = _editorFor(widget.run);
  late ConfirmedBlueprint? _confirmed = widget.run.confirmed;
  late final PlanService _planService = widget.planService ?? PlanService();
  bool _saving = false;
  bool _rebuilding = false;
  bool _planning = false;
  int _planCount = PlanLimits.minPlans;

  /// A rule was added from an image; once saved, offer to plan again.
  bool _fixPending = false;

  static BlueprintEditor? _editorFor(BlueprintRun run) {
    final draft = run.draft;
    return draft == null ? null : BlueprintEditor.fromDraft(draft);
  }

  void _update(BlueprintEditor editor) => setState(() => _editor = editor);

  Future<void> _save() async {
    final editor = _editor;
    if (editor == null || !editor.canSave || _saving) return;
    setState(() => _saving = true);
    try {
      final confirmed = await widget.service.save(
        _run.assetId,
        editor.blueprint,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _confirmed = confirmed;
        _editor = editor.markSaved(confirmed.blueprint);
      });
      if (_fixPending) {
        _fixPending = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Blueprint saved. Plan again so new images follow it.',
            ),
            action: SnackBarAction(label: 'Plan again', onPressed: _plan),
          ),
        );
      }
    } on BlueprintException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      debugPrint('JustPost: blueprint save failed — ${error.runtimeType}');
      _showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rebuild() async {
    if (_rebuilding) return;
    final editor = _editor;
    if (editor != null && editor.isEdited) {
      final discard = await _confirm(
        'Rebuild the draft?',
        'Your unsaved edits will be replaced by a new AI draft.',
      );
      if (discard != true) return;
    }
    setState(() => _rebuilding = true);
    try {
      final run = await widget.service.build(_run.assetId);
      if (!mounted) return;
      setState(() {
        _run = run;
        _editor = _editorFor(run);
        _confirmed = run.confirmed ?? _confirmed;
      });
    } on BlueprintException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      debugPrint('JustPost: blueprint rebuild failed — ${error.runtimeType}');
      _showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  /// Why variations can't be planned yet, or null when they can.
  String? get _planBlocker {
    final confirmed = _confirmed;
    final editor = _editor;
    if (confirmed == null || (editor != null && editor.isDirty)) {
      return 'Save the blueprint to plan variations.';
    }
    if (confirmed.blueprint.analysisRunId != _run.analysisRunId) {
      return 'Save a blueprint for the current analysis first.';
    }
    return null;
  }

  Future<void> _plan() async {
    final confirmed = _confirmed;
    if (_planning || confirmed == null || _planBlocker != null) return;
    setState(() => _planning = true);
    try {
      final run = await _planService.plan(_run.assetId, _planCount);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      await Navigator.of(context).push(
        CreateStep.plans.route<void>(
          (_) => PlansScreen(
            run: run,
            blueprint: confirmed.blueprint,
            service: _planService,
            referencePath: widget.referencePath,
            showInspection: widget.showInspection,
            onFixBlueprint: _fixFromImage,
          ),
        ),
      );
    } on PlanException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      debugPrint('JustPost: planning failed — ${error.runtimeType}');
      _showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  /// Comes back here from an image and asks for a new "Must keep" rule,
  /// showing the checker's [reasons] if the image didn't pass.
  Future<void> _fixFromImage(List<String> reasons) async {
    final route = ModalRoute.of(context);
    Navigator.of(context).popUntil((r) => r == route || r.isFirst);
    final editor = _editor;
    const section = BlueprintSection.mustKeep;
    if (editor == null) {
      _showMessage('Rebuild the draft to edit the blueprint.');
      return;
    }
    if (editor.blueprint.items(section).length >= section.maxItems) {
      _showMessage('"Must keep" is full. Edit one of its items instead.');
      return;
    }
    final text = await showTextEditDialog(
      context,
      title: 'Add to "${section.label}"',
      maxLength: section.maxTextLength,
      message: [
        if (reasons.isNotEmpty)
          'The checker said:\n${reasons.map((r) => '• $r').join('\n')}\n',
        'Describe what the image got wrong as a rule every image must '
            'follow. Be specific, for example about the camera angle.',
      ].join('\n'),
      hint: 'e.g. Shot from slightly above eye level, as in the reference',
    );
    if (!mounted || text == null || text.trim().isEmpty) return;
    _fixPending = true;
    _update(_editor!.add(section, text));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool?> _confirm(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askText({
    required String title,
    String initial = '',
    required int maxLength,
    bool allowEmpty = false,
  }) {
    return showTextEditDialog(
      context,
      title: title,
      initial: initial,
      maxLength: maxLength,
      allowEmpty: allowEmpty,
    );
  }

  Future<void> _editItem(BlueprintSection section, BlueprintItem item) async {
    final text = await _askText(
      title: 'Edit "${section.label}" item',
      initial: item.text,
      maxLength: section.maxTextLength,
    );
    if (text == null || text.trim() == item.text) return;
    _update(_editor!.editText(section, item.id, text));
  }

  Future<void> _addItem(BlueprintSection section) async {
    final text = await _askText(
      title: 'Add to "${section.label}"',
      maxLength: section.maxTextLength,
    );
    if (text == null || text.trim().isEmpty) return;
    _update(_editor!.add(section, text));
  }

  Future<void> _editCopy({required bool primary}) async {
    final strategy = _editor!.blueprint.copyStrategy;
    final text = await _askText(
      title: primary ? 'Main text pattern' : 'Secondary text pattern',
      initial: primary
          ? strategy.primaryPattern
          : strategy.secondaryPattern ?? '',
      maxLength: 200,
      allowEmpty: !primary,
    );
    if (text == null) return;
    _update(
      primary
          ? _editor!.editCopy(primaryPattern: text)
          : _editor!.editCopy(secondaryPattern: text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final editor = _editor;
    final confirmed = _confirmed;

    return Scaffold(
      key: const Key('blueprint-screen'),
      backgroundColor: AppColors.canvas,
      body: AmbientBackground(
        child: AppScreen(
          leading: Row(
            children: [
              GlassIconButton(
                icon: CupertinoIcons.chevron_left,
                semanticLabel: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  'Blueprint',
                  style: Theme.of(context).textTheme.headlineMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
            children: [
              const CreateStepBar(current: CreateStep.blueprint),
              const SizedBox(height: 12),
              CheckStatusCard(
                attempts: _run.attempts,
                passed: _run.passed,
                passedSummary:
                    'Passed on attempt ${_run.attempts.length}. Edit the '
                    'draft below, then save it to confirm.',
                failedSummary:
                    'No attempt passed, so there is no new draft. Rebuild to '
                    'try again.',
              ),
              if (confirmed != null) ...[
                const SizedBox(height: 12),
                _ConfirmedNote(
                  confirmed: confirmed,
                  currentAnalysisRunId: _run.analysisRunId,
                ),
              ],
              if (editor != null) ..._buildEditor(context, editor),
              const SizedBox(height: 16),
              GhostButton(
                key: const Key('rebuild-blueprint-button'),
                label: _rebuilding ? 'Rebuilding…' : 'Rebuild draft',
                icon: CupertinoIcons.arrow_clockwise,
                onPressed: _rebuilding || _saving || _planning
                    ? null
                    : _rebuild,
              ),
              ..._buildPlanning(context),
              if (widget.showInspection && _run.rawExposed) ...[
                const SizedBox(height: 24),
                RawOutputPanel(attempts: _run.attempts),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPlanning(BuildContext context) {
    final blocker = _planBlocker;
    final busy = _saving || _rebuilding;
    final textTheme = Theme.of(context).textTheme;

    return [
      const SizedBox(height: 28),
      const SectionTitle('Variations'),
      AppCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How many plans?', style: textTheme.bodyMedium),
            const SizedBox(height: 10),
            CupertinoSlidingSegmentedControl<int>(
              key: const Key('plan-count'),
              groupValue: _planCount,
              onValueChanged: (value) {
                if (value != null) setState(() => _planCount = value);
              },
              children: {
                for (var n = PlanLimits.minPlans; n <= PlanLimits.maxPlans; n++)
                  n: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('$n'),
                  ),
              },
            ),
            if (blocker != null) ...[
              const SizedBox(height: 10),
              Text(
                blocker,
                key: const Key('plan-blocker'),
                style: textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 14),
            PrimaryButton(
              key: const Key('plan-variations-button'),
              label: 'Plan variations',
              icon: CupertinoIcons.square_stack_3d_up,
              busy: _planning,
              onPressed: blocker == null && !busy ? _plan : null,
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildEditor(BuildContext context, BlueprintEditor editor) {
    final blueprint = editor.blueprint;
    final strategy = blueprint.copyStrategy;
    final problems = editor.problems;
    final textTheme = Theme.of(context).textTheme;

    return [
      const SizedBox(height: 20),
      const SectionTitle('Creative family'),
      DetailsCard(
        rows: [
          ('Family', humanize(blueprint.creativeFamily)),
          ('Objective', blueprint.objective),
        ],
      ),
      for (final section in BlueprintSection.values) ...[
        const SizedBox(height: 20),
        SectionTitle(
          section.label,
          trailing: Text(
            '${blueprint.items(section).length}/${section.maxItems}',
            style: textTheme.labelSmall,
          ),
        ),
        _SectionCard(
          key: Key('section-${section.name}'),
          section: section,
          items: blueprint.items(section),
          onEdit: (item) => _editItem(section, item),
          onDelete: (item) => _update(editor.delete(section, item.id)),
          onMove: (item, to) => _update(editor.move(item.id, section, to)),
          onAdd: blueprint.items(section).length < section.maxItems
              ? () => _addItem(section)
              : null,
        ),
      ],
      const SizedBox(height: 20),
      const SectionTitle('Copy strategy'),
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        child: Column(
          children: [
            _EditableRow(label: 'Text role', value: humanize(strategy.role)),
            const Divider(),
            _EditableRow(
              label: 'Main pattern',
              value: strategy.primaryPattern,
              onTap: () => _editCopy(primary: true),
            ),
            const Divider(),
            _EditableRow(
              label: 'Secondary',
              value: strategy.secondaryPattern ?? 'None',
              onTap: () => _editCopy(primary: false),
            ),
          ],
        ),
      ),
      if (problems.isNotEmpty) ...[
        const SizedBox(height: 16),
        for (final problem in problems)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              '• $problem',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.danger),
            ),
          ),
      ],
      const SizedBox(height: 20),
      PrimaryButton(
        key: const Key('save-blueprint-button'),
        label: editor.isDirty ? 'Save blueprint' : 'Saved',
        icon: CupertinoIcons.checkmark_alt,
        busy: _saving,
        onPressed: editor.canSave && !_rebuilding && !_planning ? _save : null,
      ),
    ];
  }
}

class _ConfirmedNote extends StatelessWidget {
  const _ConfirmedNote({
    required this.confirmed,
    required this.currentAnalysisRunId,
  });

  final ConfirmedBlueprint confirmed;
  final String currentAnalysisRunId;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final stale = confirmed.blueprint.analysisRunId != currentAnalysisRunId;

    return AppCard(
      key: const Key('confirmed-note'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            CupertinoIcons.checkmark_shield_fill,
            color: AppColors.accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Confirmed, version ${confirmed.version}',
                  style: textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
                if (stale)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Built from an earlier analysis of this slide.',
                      style: textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.section,
    required this.items,
    required this.onEdit,
    required this.onDelete,
    required this.onMove,
    required this.onAdd,
  });

  final BlueprintSection section;
  final List<BlueprintItem> items;
  final ValueChanged<BlueprintItem> onEdit;
  final ValueChanged<BlueprintItem> onDelete;
  final void Function(BlueprintItem item, BlueprintSection to) onMove;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0) const Divider(height: 1),
            _ItemRow(
              section: section,
              item: item,
              onTap: () => onEdit(item),
              onDelete: () => onDelete(item),
              onMove: (to) => onMove(item, to),
            ),
          ],
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('Nothing here yet.', style: textTheme.bodyMedium),
            ),
          const Divider(height: 1),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('add-${section.name}'),
              onPressed: onAdd,
              icon: const Icon(CupertinoIcons.add, size: 16),
              label: const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.section,
    required this.item,
    required this.onTap,
    required this.onDelete,
    required this.onMove,
  });

  final BlueprintSection section;
  final BlueprintItem item;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final ValueChanged<BlueprintSection> onMove;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.text,
                    style: textTheme.titleMedium?.copyWith(fontSize: 14),
                  ),
                  if (section.isDimension && item.examples.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'e.g. ${item.examples.join(', ')}',
                        style: textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OriginTag(fromUser: item.fromUser),
            PopupMenuButton<_ItemAction>(
              tooltip: 'Item options',
              icon: const Icon(CupertinoIcons.ellipsis, size: 18),
              onSelected: (action) =>
                  action.moveTo == null ? onDelete() : onMove(action.moveTo!),
              itemBuilder: (context) => [
                for (final target in BlueprintSection.values)
                  if (target != section)
                    PopupMenuItem(
                      value: _ItemAction(target),
                      child: Text('Move to ${target.label}'),
                    ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _ItemAction(null),
                  child: Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A menu choice: move to a section, or delete when [moveTo] is null.
class _ItemAction {
  const _ItemAction(this.moveTo);

  final BlueprintSection? moveTo;
}

class _EditableRow extends StatelessWidget {
  const _EditableRow({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: textTheme.bodyMedium),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: textTheme.titleMedium?.copyWith(fontSize: 14),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(
                CupertinoIcons.pencil,
                size: 14,
                color: AppColors.textTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
