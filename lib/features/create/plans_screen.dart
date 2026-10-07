import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/build_flags.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import 'blueprint_service.dart';
import 'create_steps.dart';
import 'generation_service.dart';
import 'model_run_widgets.dart';
import 'plan_editor.dart';
import 'plan_service.dart';
import 'variations_screen.dart';

/// Shows a plan run, lets the user edit the draft plans, and saves the edited
/// version as the confirmed plans.
class PlansScreen extends StatefulWidget {
  const PlansScreen({
    super.key,
    required this.run,
    required this.blueprint,
    required this.service,
    this.generationService,
    this.referencePath,
    this.showInspection = showAiInspection,
    this.onFixBlueprint,
  });

  final PlanRun run;

  /// Goes back to the blueprint to add a rule; given the image's reasons.
  final ValueChanged<List<String>>? onFixBlueprint;

  /// The confirmed blueprint the plans are written from.
  final Blueprint blueprint;
  final PlanService service;
  final GenerationService? generationService;

  /// The slide's analysis copy, shown next to the generated images.
  final String? referencePath;
  final bool showInspection;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late PlanRun _run = widget.run;
  late PlanEditor? _editor = _editorFor(widget.run);
  late ConfirmedPlans? _confirmed = widget.run.confirmed;
  bool _saving = false;
  bool _replanning = false;

  PlanEditor? _editorFor(PlanRun run) {
    final draft = run.draft;
    return draft == null ? null : PlanEditor.fromDraft(draft, widget.blueprint);
  }

  void _update(PlanEditor editor) => setState(() => _editor = editor);

  Future<void> _save() async {
    final editor = _editor;
    if (editor == null || !editor.canSave || _saving) return;
    setState(() => _saving = true);
    try {
      final confirmed = await widget.service.save(_run.assetId, editor.plans);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _confirmed = confirmed;
        _editor = editor.markSaved(confirmed.plans);
      });
    } on PlanException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      debugPrint('JustPost: plan save failed — ${error.runtimeType}');
      _showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _replan() async {
    if (_replanning) return;
    final editor = _editor;
    if (editor != null && editor.isEdited) {
      final discard = await _confirm(
        'Plan again?',
        'Your unsaved edits will be replaced by new AI plans.',
      );
      if (discard != true) return;
    }
    setState(() => _replanning = true);
    try {
      final run = await widget.service.plan(_run.assetId, _run.count);
      if (!mounted) return;
      setState(() {
        _run = run;
        _editor = _editorFor(run);
        _confirmed = run.confirmed ?? _confirmed;
      });
    } on PlanException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      debugPrint('JustPost: replanning failed — ${error.runtimeType}');
      _showMessage('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _replanning = false);
    }
  }

  /// Why images can't be created yet, or null when they can.
  String? get _imageBlocker {
    final confirmed = _confirmed;
    final editor = _editor;
    if (confirmed == null || (editor != null && editor.isDirty)) {
      return 'Save the plans to create images.';
    }
    if (confirmed.plans.blueprintVersion != _run.blueprintVersion) {
      return 'These plans are for an earlier blueprint. Plan again first.';
    }
    if (confirmed.plans.plans.isEmpty) return 'Add a plan first.';
    return null;
  }

  void _createImages() {
    final confirmed = _confirmed;
    if (confirmed == null || _imageBlocker != null) return;
    Navigator.of(context).push(
      CreateStep.images.route<void>(
        (_) => VariationsScreen(
          assetId: _run.assetId,
          plans: confirmed,
          blueprint: widget.blueprint,
          service: widget.generationService ?? GenerationService(),
          referencePath: widget.referencePath,
          onFixBlueprint: widget.onFixBlueprint,
        ),
      ),
    );
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

  Future<void> _editTitle(VariationPlan plan) async {
    final text = await showTextEditDialog(
      context,
      title: 'Plan title',
      initial: plan.title,
      maxLength: PlanLimits.maxTitle,
      singleLine: true,
    );
    if (text == null || text.trim() == plan.title) return;
    _update(_editor!.editTitle(plan.id, text));
  }

  Future<void> _editValue(VariationPlan plan, int index) async {
    final change = plan.changes[index];
    final text = await showTextEditDialog(
      context,
      title: _editor!.dimensionName(change.dimensionId),
      initial: change.value,
      maxLength: PlanLimits.maxValue,
    );
    if (text == null || text.trim() == change.value) return;
    _update(_editor!.editChange(plan.id, index, value: text));
  }

  Future<void> _addChange(VariationPlan plan, BlueprintItem dimension) async {
    final text = await showTextEditDialog(
      context,
      title: dimension.text,
      maxLength: PlanLimits.maxValue,
    );
    if (text == null || text.trim().isEmpty) return;
    _update(_editor!.addChange(plan.id, dimension.id, text));
  }

  Future<void> _editCopy(VariationPlan plan, {required bool text}) async {
    final copy = plan.copy ?? const PlanCopy(text: '', pattern: '');
    final value = await showTextEditDialog(
      context,
      title: text ? 'Slide text' : 'Text style',
      initial: text ? copy.text : copy.pattern,
      maxLength: text ? PlanLimits.maxHookText : PlanLimits.maxPattern,
      singleLine: true,
    );
    if (value == null) return;
    _update(
      text
          ? _editor!.editCopy(plan.id, text: value)
          : _editor!.editCopy(plan.id, pattern: value),
    );
  }

  Future<void> _addPlan() async {
    final title = await showTextEditDialog(
      context,
      title: 'New plan',
      maxLength: PlanLimits.maxTitle,
      singleLine: true,
    );
    if (title == null || title.trim().isEmpty) return;
    _update(_editor!.addPlan(title));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final editor = _editor;
    final confirmed = _confirmed;
    final count = _run.count;

    return Scaffold(
      key: const Key('plans-screen'),
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
                  'Variation plans',
                  style: Theme.of(context).textTheme.headlineMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
            children: [
              const CreateStepBar(current: CreateStep.plans),
              const SizedBox(height: 12),
              CheckStatusCard(
                attempts: _run.attempts,
                passed: _run.passed,
                passedSummary:
                    'Passed on attempt ${_run.attempts.length}. Edit the '
                    'plans below, then save them to confirm.',
                failedSummary:
                    'No attempt passed, so there are no new plans. Plan again '
                    'to retry.',
              ),
              if (confirmed != null) ...[
                const SizedBox(height: 12),
                _ConfirmedPlansNote(
                  confirmed: confirmed,
                  currentBlueprintVersion: _run.blueprintVersion,
                ),
              ],
              if (editor != null) ..._buildEditor(context, editor),
              const SizedBox(height: 16),
              GhostButton(
                key: const Key('replan-button'),
                label: _replanning
                    ? 'Planning…'
                    : 'Plan again ($count ${count == 1 ? 'plan' : 'plans'})',
                icon: CupertinoIcons.arrow_clockwise,
                onPressed: _replanning || _saving ? null : _replan,
              ),
              ..._buildImages(context),
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

  List<Widget> _buildImages(BuildContext context) {
    final blocker = _imageBlocker;
    final busy = _saving || _replanning;

    return [
      const SizedBox(height: 28),
      const SectionTitle('Images'),
      AppCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              blocker ??
                  'Creates one image per confirmed plan and checks each '
                      'against the blueprint.',
              key: Key(blocker == null ? 'image-ready' : 'image-blocker'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            PrimaryButton(
              key: const Key('create-images-button'),
              label: 'Create images',
              icon: CupertinoIcons.photo_on_rectangle,
              onPressed: blocker == null && !busy ? _createImages : null,
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildEditor(BuildContext context, PlanEditor editor) {
    final plans = editor.plans.plans;
    final problems = editor.problems;
    final textTheme = Theme.of(context).textTheme;

    return [
      for (final (index, plan) in plans.indexed) ...[
        const SizedBox(height: 20),
        SectionTitle(
          'Plan ${index + 1}',
          trailing: OriginTag(fromUser: plan.fromUser),
        ),
        _PlanCard(
          key: Key('plan-${plan.id}'),
          plan: plan,
          editor: editor,
          onEditTitle: () => _editTitle(plan),
          onDelete: () => _update(editor.deletePlan(plan.id)),
          onEditValue: (changeIndex) => _editValue(plan, changeIndex),
          onSwitchDimension: (changeIndex, dimensionId) => _update(
            editor.editChange(plan.id, changeIndex, dimensionId: dimensionId),
          ),
          onRemoveChange: (changeIndex) =>
              _update(editor.removeChange(plan.id, changeIndex)),
          onAddChange: (dimension) => _addChange(plan, dimension),
          onEditCopy: ({required bool text}) => _editCopy(plan, text: text),
        ),
      ],
      if (plans.isEmpty) ...[
        const SizedBox(height: 20),
        AppCard(child: Text('No plans left.', style: textTheme.bodyMedium)),
      ],
      const SizedBox(height: 16),
      GhostButton(
        key: const Key('add-plan-button'),
        label: 'Add plan',
        icon: CupertinoIcons.add,
        onPressed: editor.canAddPlan ? _addPlan : null,
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
        key: const Key('save-plans-button'),
        label: editor.isDirty ? 'Save plans' : 'Saved',
        icon: CupertinoIcons.checkmark_alt,
        busy: _saving,
        onPressed: editor.canSave && !_replanning ? _save : null,
      ),
    ];
  }
}

class _ConfirmedPlansNote extends StatelessWidget {
  const _ConfirmedPlansNote({
    required this.confirmed,
    required this.currentBlueprintVersion,
  });

  final ConfirmedPlans confirmed;
  final int currentBlueprintVersion;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final stale = confirmed.plans.blueprintVersion != currentBlueprintVersion;
    final count = confirmed.plans.plans.length;

    return AppCard(
      key: const Key('confirmed-plans-note'),
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
                  'Confirmed, version ${confirmed.version} · '
                  '$count ${count == 1 ? 'plan' : 'plans'}',
                  style: textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
                if (stale)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Written for an earlier version of the blueprint.',
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

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.editor,
    required this.onEditTitle,
    required this.onDelete,
    required this.onEditValue,
    required this.onSwitchDimension,
    required this.onRemoveChange,
    required this.onAddChange,
    required this.onEditCopy,
  });

  final VariationPlan plan;
  final PlanEditor editor;
  final VoidCallback onEditTitle;
  final VoidCallback onDelete;
  final ValueChanged<int> onEditValue;
  final void Function(int index, String dimensionId) onSwitchDimension;
  final ValueChanged<int> onRemoveChange;
  final ValueChanged<BlueprintItem> onAddChange;
  final void Function({required bool text}) onEditCopy;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final unused = editor.unusedDimensions(plan);
    final copy = plan.copy;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onEditTitle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      plan.title.isEmpty ? 'Untitled plan' : plan.title,
                      style: textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Delete plan',
                icon: const Icon(CupertinoIcons.trash, size: 18),
                onPressed: onDelete,
              ),
            ],
          ),
          const Divider(height: 1),
          for (final (index, change) in plan.changes.indexed) ...[
            if (index > 0) const Divider(height: 1),
            _ChangeRow(
              label: editor.dimensionName(change.dimensionId),
              value: change.value,
              switchTo: unused,
              onTap: () => onEditValue(index),
              onSwitch: (dimensionId) => onSwitchDimension(index, dimensionId),
              onRemove: () => onRemoveChange(index),
            ),
          ],
          if (plan.changes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No changes yet.', style: textTheme.bodyMedium),
            ),
          const Divider(height: 1),
          Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<BlueprintItem>(
              key: Key('add-change-${plan.id}'),
              enabled: unused.isNotEmpty,
              tooltip: 'Add change',
              onSelected: onAddChange,
              itemBuilder: (context) => [
                for (final dimension in unused)
                  PopupMenuItem(value: dimension, child: Text(dimension.text)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.add,
                      size: 16,
                      color: unused.isEmpty
                          ? AppColors.textTertiary
                          : AppColors.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Add change',
                      style: textTheme.titleMedium?.copyWith(
                        fontSize: 14,
                        color: unused.isEmpty
                            ? AppColors.textTertiary
                            : AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (copy != null) ...[
            const Divider(height: 1),
            _CopyRow(
              key: Key('copy-text-${plan.id}'),
              label: 'Slide text',
              value: copy.text.isEmpty ? 'None yet' : copy.text,
              onTap: () => onEditCopy(text: true),
            ),
            const Divider(height: 1),
            _CopyRow(
              label: 'Text style',
              value: copy.pattern.isEmpty ? 'None yet' : copy.pattern,
              onTap: () => onEditCopy(text: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.label,
    required this.value,
    required this.switchTo,
    required this.onTap,
    required this.onSwitch,
    required this.onRemove,
  });

  final String label;
  final String value;
  final List<BlueprintItem> switchTo;
  final VoidCallback onTap;
  final ValueChanged<String> onSwitch;
  final VoidCallback onRemove;

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
                  Text(label, style: textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    value.isEmpty ? 'No value yet' : value,
                    style: textTheme.titleMedium?.copyWith(fontSize: 14),
                  ),
                ],
              ),
            ),
            // A null value would count as cancelling, so '' means remove.
            PopupMenuButton<String>(
              tooltip: 'Change options',
              icon: const Icon(CupertinoIcons.ellipsis, size: 18),
              onSelected: (dimensionId) =>
                  dimensionId.isEmpty ? onRemove() : onSwitch(dimensionId),
              itemBuilder: (context) => [
                for (final dimension in switchTo)
                  PopupMenuItem(
                    value: dimension.id,
                    child: Text('Change ${dimension.text} instead'),
                  ),
                if (switchTo.isNotEmpty) const PopupMenuDivider(),
                const PopupMenuItem(value: '', child: Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: textTheme.titleMedium?.copyWith(fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              CupertinoIcons.pencil,
              size: 14,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
