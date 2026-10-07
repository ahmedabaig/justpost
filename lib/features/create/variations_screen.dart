import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import '../library/slideshow_screen.dart';
import '../library/slideshow_service.dart';
import 'blueprint_service.dart';
import 'create_steps.dart';
import 'generation_service.dart';
import 'model_run_widgets.dart';
import 'plan_service.dart';
import 'render_service.dart';

/// Creates one image per confirmed plan, all at once. The server checks each
/// against the blueprint and its plan before replying; images that pass get
/// their slide text drawn on by the server. Images that didn't pass are shown
/// only when the server's inspection switch is on; otherwise the card gives
/// the reasons. **Review set** opens the final set made from the slides.
class VariationsScreen extends StatefulWidget {
  const VariationsScreen({
    super.key,
    required this.assetId,
    required this.plans,
    required this.blueprint,
    required this.service,
    this.renderService,
    this.slideshowService,
    this.exporter,
    this.referencePath,
    this.startNow = true,
    this.onFixBlueprint,
  });

  final String assetId;

  /// Goes back to the blueprint to add a rule; given the image's reasons.
  final ValueChanged<List<String>>? onFixBlueprint;
  final ConfirmedPlans plans;

  /// The confirmed blueprint the plans were written from.
  final Blueprint blueprint;
  final GenerationService service;
  final RenderService? renderService;
  final SlideshowService? slideshowService;
  final SlideExporter? exporter;

  /// The slide's analysis copy, shown for comparison.
  final String? referencePath;

  /// Starts every plan's image when the screen opens.
  final bool startNow;

  @override
  State<VariationsScreen> createState() => _VariationsScreenState();
}

enum _Stage { waiting, creating, created, failed }

@immutable
class _Slot {
  const _Slot(
    this.stage, {
    this.image,
    this.message,
    this.url,
    this.slide,
    this.slideUrl,
    this.rendering = false,
    this.renderError,
    this.style = SlideStyle.outlined,
    this.position = SlidePosition.reference,
    this.showPlain = false,
  });

  final _Stage stage;
  final VariationImage? image;
  final String? message;

  /// The image without text.
  final Future<String>? url;

  /// The last slide drawn successfully, kept while a new one is drawn.
  final SlideRender? slide;
  final Future<String>? slideUrl;
  final bool rendering;
  final String? renderError;
  final SlideStyle style;
  final SlidePosition position;
  final bool showPlain;

  /// [renderError] is always replaced, so leaving it out clears it.
  _Slot withRender({
    SlideRender? slide,
    Future<String>? slideUrl,
    required bool rendering,
    String? renderError,
    SlideStyle? style,
    SlidePosition? position,
    bool? showPlain,
  }) => _Slot(
    stage,
    image: image,
    message: message,
    url: url,
    slide: slide ?? this.slide,
    slideUrl: slideUrl ?? this.slideUrl,
    rendering: rendering,
    renderError: renderError,
    style: style ?? this.style,
    position: position ?? this.position,
    showPlain: showPlain ?? this.showPlain,
  );
}

class _VariationsScreenState extends State<VariationsScreen> {
  late final RenderService _renderService =
      widget.renderService ?? RenderService();
  late final Map<String, _Slot> _slots = {
    for (final plan in widget.plans.plans.plans)
      plan.id: const _Slot(_Stage.waiting),
  };
  late final Future<String>? _referenceUrl = switch (widget.referencePath) {
    final path? => _url(path),
    null => null,
  };
  late final Map<String, String> _dimensionNames = {
    for (final item in widget.blueprint.items(BlueprintSection.canVary))
      item.id: item.text,
  };

  @override
  void initState() {
    super.initState();
    if (widget.startNow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final plan in widget.plans.plans.plans) {
          _generate(plan.id);
        }
      });
    }
  }

  /// The URL may fail before its image widget listens; the widget still shows
  /// the error, but it doesn't surface as an unhandled one.
  Future<String> _url(String path) =>
      widget.service.downloadUrl(path)..ignore();

  Future<void> _generate(String planId) async {
    if (!mounted || _slots[planId]?.stage == _Stage.creating) return;
    setState(() => _slots[planId] = const _Slot(_Stage.creating));
    _Slot slot;
    try {
      final image = await widget.service.generate(widget.assetId, planId);
      final path = image.imagePath;
      slot = _Slot(
        image.created ? _Stage.created : _Stage.failed,
        image: image,
        url: image.created && path != null ? _url(path) : null,
      );
      if (image.created) HapticFeedback.lightImpact();
    } on GenerationException catch (error) {
      slot = _Slot(_Stage.failed, message: error.message);
    } catch (error) {
      debugPrint('JustPost: image generation failed — ${error.runtimeType}');
      slot = const _Slot(
        _Stage.failed,
        message: 'Something went wrong. Please try again.',
      );
    }
    if (!mounted) return;
    setState(() => _slots[planId] = slot);
    if (slot.url != null) _render(planId);
  }

  /// Draws the slide text with the slot's style and position, or the given
  /// ones. On failure the choice goes back to the last slide that was drawn.
  Future<void> _render(
    String planId, {
    SlideStyle? style,
    SlidePosition? position,
  }) async {
    final slot = _slots[planId];
    final image = slot?.image;
    if (!mounted ||
        slot == null ||
        image == null ||
        slot.stage != _Stage.created ||
        slot.url == null ||
        slot.rendering) {
      return;
    }
    final chosen = slot.withRender(
      rendering: true,
      style: style,
      position: position,
    );
    setState(() => _slots[planId] = chosen);

    SlideRender? slide;
    String? error;
    try {
      slide = await _renderService.render(
        widget.assetId,
        image.runId,
        style: chosen.style,
        position: chosen.position,
      );
      if (!slide.rendered) {
        error = slide.issues.isEmpty
            ? 'Adding the text failed.'
            : slide.issues.join(' ');
      }
    } on RenderException catch (exception) {
      error = exception.message;
    } catch (exception) {
      debugPrint('JustPost: adding text failed — ${exception.runtimeType}');
      error = 'Something went wrong. Please try again.';
    }
    if (!mounted) return;

    final current = _slots[planId]!;
    final path = slide?.imagePath;
    setState(() {
      _slots[planId] = error == null
          ? current.withRender(
              rendering: false,
              slide: slide,
              slideUrl: path == null ? null : _url(path),
              // The first slide may have been moved off the subject.
              style: slide?.style,
              position: slide?.position,
            )
          : current.withRender(
              rendering: false,
              renderError: error,
              style: slot.style,
              position: slot.position,
            );
    });
  }

  /// At least one slide drawn on a passed image, and nothing still running.
  bool get _canReview =>
      _slots.values.any(
        (slot) => slot.image?.passed == true && slot.slide != null,
      ) &&
      _slots.values.every(
        (slot) => slot.stage != _Stage.creating && !slot.rendering,
      );

  void _review() {
    Navigator.of(context).push(
      CreateStep.set.route<void>(
        (_) => SlideshowScreen(
          assetId: widget.assetId,
          service: widget.slideshowService ?? SlideshowService(),
          exporter: widget.exporter,
          showSteps: true,
        ),
      ),
    );
  }

  /// A blueprint change means new plans and new images for every plan, so
  /// say what will be lost first.
  Future<void> _fixBlueprint(String planId) async {
    final fix = widget.onFixBlueprint;
    if (fix == null) return;
    final passed = _slots.values
        .where((slot) => slot.image?.passed == true)
        .length;
    final running = _slots.values.any(
      (slot) => slot.stage == _Stage.creating || slot.rendering,
    );
    if (passed > 0 || running) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Change the blueprint?'),
          content: Text(
            [
              'After changing the blueprint you plan again and make every '
                  'image again.',
              if (passed == 1) 'The 1 image that passed will be replaced.',
              if (passed > 1)
                'The $passed images that passed will be replaced.',
              if (running) 'Images still being made will be lost.',
            ].join(' '),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('fix-blueprint-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    fix(_slots[planId]?.image?.issues ?? const []);
  }

  void _togglePlain(String planId) {
    final slot = _slots[planId];
    if (slot == null) return;
    setState(() {
      _slots[planId] = slot.withRender(
        rendering: slot.rendering,
        renderError: slot.renderError,
        showPlain: !slot.showPlain,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final plans = widget.plans.plans.plans;
    final referenceUrl = _referenceUrl;

    return Scaffold(
      key: const Key('variations-screen'),
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
                  'Variations',
                  style: Theme.of(context).textTheme.headlineMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
            children: [
              const CreateStepBar(current: CreateStep.images),
              const SizedBox(height: 12),
              const _ChecksNote(),
              if (referenceUrl != null) ...[
                const SizedBox(height: 20),
                const SectionTitle('Reference'),
                SizedBox(
                  height: 220,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _ImageFrame(
                      aspectRatio: 9 / 16,
                      child: _NetworkImage(url: referenceUrl),
                    ),
                  ),
                ),
              ],
              for (final (index, plan) in plans.indexed) ...[
                const SizedBox(height: 20),
                SectionTitle(
                  'Plan ${index + 1}',
                  trailing: OriginTag(fromUser: plan.fromUser),
                ),
                _VariationCard(
                  key: Key('variation-${plan.id}'),
                  plan: plan,
                  slot: _slots[plan.id] ?? const _Slot(_Stage.waiting),
                  dimensionName: (id) => _dimensionNames[id] ?? id,
                  onRetry: () => _generate(plan.id),
                  onStyle: (style) => _render(plan.id, style: style),
                  onPosition: (position) =>
                      _render(plan.id, position: position),
                  onTogglePlain: () => _togglePlain(plan.id),
                  onFixBlueprint: widget.onFixBlueprint == null
                      ? null
                      : () => _fixBlueprint(plan.id),
                ),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('review-set'),
                label: 'Review set',
                icon: CupertinoIcons.square_stack_3d_up,
                onPressed: _canReview ? _review : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChecksNote extends StatelessWidget {
  const _ChecksNote();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      key: const Key('checks-note'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            CupertinoIcons.checkmark_shield,
            color: AppColors.textSecondary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Checked against your blueprint',
                  style: textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  'Each image is checked against the blueprint and its plan. '
                  'Only images that pass become slides, and only those can '
                  'go into your set.',
                  style: textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VariationCard extends StatelessWidget {
  const _VariationCard({
    super.key,
    required this.plan,
    required this.slot,
    required this.dimensionName,
    required this.onRetry,
    required this.onStyle,
    required this.onPosition,
    required this.onTogglePlain,
    this.onFixBlueprint,
  });

  final VariationPlan plan;
  final _Slot slot;
  final String Function(String id) dimensionName;
  final VoidCallback onRetry;
  final ValueChanged<SlideStyle> onStyle;
  final ValueChanged<SlidePosition> onPosition;
  final VoidCallback onTogglePlain;
  final VoidCallback? onFixBlueprint;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final copy = plan.copy;

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            plan.title.isEmpty ? 'Untitled plan' : plan.title,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          for (final change in plan.changes)
            Text(
              '${dimensionName(change.dimensionId)}: ${change.value}',
              style: textTheme.bodyMedium,
            ),
          const SizedBox(height: 14),
          _stageView(context),
          if (copy != null) ...[
            const Divider(height: 28),
            Text('Slide text', style: textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(
              copy.text,
              style: textTheme.titleMedium?.copyWith(fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stageView(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final image = slot.image;

    switch (slot.stage) {
      case _Stage.waiting:
        return Text('Waiting to start…', style: textTheme.bodyMedium);
      case _Stage.creating:
        return Row(
          key: const Key('variation-creating'),
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Creating and checking the image. This can take a minute or '
                'two.',
                style: textTheme.bodyMedium,
              ),
            ),
          ],
        );
      case _Stage.failed:
        final reasons = [?slot.message, ...?image?.issues];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'No image',
              style: textTheme.titleMedium?.copyWith(fontSize: 14),
            ),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '• $reason',
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            GhostButton(
              key: Key('retry-${plan.id}'),
              label: 'Try again',
              icon: CupertinoIcons.arrow_clockwise,
              onPressed: onRetry,
            ),
          ],
        );
      case _Stage.created:
        final passed = image?.passed ?? false;
        final slideUrl = slot.showPlain ? null : slot.slideUrl;
        final url = slideUrl ?? slot.url;
        final width = image?.width;
        final height = image?.height;
        final details = [
          '${((image?.latencyMs ?? 0) / 1000).round()} s',
          ?image?.model,
        ].join(' · ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!passed) ...[
              _NotPassed(
                key: Key('not-passed-${plan.id}'),
                checked: image?.status == 'rejected',
                reasons: image?.issues ?? const [],
                onRetry: onRetry,
                retryKey: Key('retry-${plan.id}'),
              ),
              if (url != null) const SizedBox(height: 14),
            ],
            if (url != null) ...[
              _ImageFrame(
                aspectRatio: width != null && height != null && height > 0
                    ? width / height
                    : 9 / 16,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _NetworkImage(
                      key: Key(
                        slideUrl == null
                            ? 'plain-image-${plan.id}'
                            : 'slide-image-${plan.id}',
                      ),
                      url: url,
                    ),
                    if (slot.rendering)
                      const Positioned(
                        top: 10,
                        right: 10,
                        child: _RenderingBadge(),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ResultTag(passed: passed),
                  const SizedBox(width: 8),
                  Expanded(child: Text(details, style: textTheme.bodyMedium)),
                ],
              ),
              if (plan.copy != null) ..._textControls(context),
            ],
            if (image != null && image.checks.isNotEmpty)
              _CheckList(key: Key('checks-${plan.id}'), checks: image.checks),
            if (onFixBlueprint case final fix?)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('fix-blueprint-${plan.id}'),
                  onPressed: fix,
                  icon: const Icon(CupertinoIcons.wrench, size: 16),
                  label: Text(
                    passed
                        ? 'Not right? Fix in blueprint'
                        : 'Keeps going wrong? Fix in blueprint',
                  ),
                ),
              ),
          ],
        );
    }
  }

  List<Widget> _textControls(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final error = slot.renderError;
    final enabled = !slot.rendering;

    return [
      const SizedBox(height: 14),
      CupertinoSlidingSegmentedControl<SlideStyle>(
        key: Key('style-${plan.id}'),
        groupValue: slot.style,
        onValueChanged: (style) {
          if (enabled && style != null && style != slot.style) onStyle(style);
        },
        children: {
          for (final style in SlideStyle.values)
            style: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(style.label, style: const TextStyle(fontSize: 13)),
            ),
        },
      ),
      const SizedBox(height: 4),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<SlidePosition>(
            key: Key('position-${plan.id}'),
            enabled: enabled,
            tooltip: 'Text position',
            initialValue: slot.position,
            onSelected: (position) {
              if (position != slot.position) onPosition(position);
            },
            itemBuilder: (context) => [
              for (final position in SlidePosition.values)
                PopupMenuItem(value: position, child: Text(position.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'Position: ${slot.position.label}',
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(CupertinoIcons.chevron_down, size: 14),
                ],
              ),
            ),
          ),
          if (slot.slideUrl != null)
            TextButton(
              key: Key('plain-${plan.id}'),
              onPressed: onTogglePlain,
              child: Text(
                slot.showPlain ? 'Show with text' : 'Show without text',
              ),
            ),
        ],
      ),
      if (error != null)
        Text(
          '• $error',
          key: Key('render-error-${plan.id}'),
          style: textTheme.bodyMedium?.copyWith(color: AppColors.danger),
        ),
    ];
  }
}

class _RenderingBadge extends StatelessWidget {
  const _RenderingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('rendering-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 6),
          Text('Adding text…', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _ResultTag extends StatelessWidget {
  const _ResultTag({required this.passed});

  final bool passed;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.fillSubtle,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        passed ? 'PASSED CHECKS' : 'DIDN\'T PASS',
        style: passed ? style : style?.copyWith(color: AppColors.danger),
      ),
    );
  }
}

/// Why an image isn't a slide, with a way to make a new one.
class _NotPassed extends StatelessWidget {
  const _NotPassed({
    super.key,
    required this.checked,
    required this.reasons,
    required this.onRetry,
    required this.retryKey,
  });

  /// True when the check ran and the image failed it; false when the image
  /// couldn't be checked at all.
  final bool checked;
  final List<String> reasons;
  final VoidCallback onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          checked ? 'This image didn\'t pass' : 'We couldn\'t check this image',
          style: textTheme.titleMedium?.copyWith(fontSize: 14),
        ),
        for (final reason in reasons)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '• $reason',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.danger),
            ),
          ),
        const SizedBox(height: 12),
        GhostButton(
          key: retryKey,
          label: 'Try again',
          icon: CupertinoIcons.arrow_clockwise,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

/// Every question the image was checked against, collapsed by default.
class _CheckList extends StatefulWidget {
  const _CheckList({super.key, required this.checks});

  final List<VariationCheck> checks;

  @override
  State<_CheckList> createState() => _CheckListState();
}

class _CheckListState extends State<_CheckList> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton(
          onPressed: () => setState(() => _open = !_open),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.centerLeft,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'What was checked',
                  style: textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
              ),
              Icon(
                _open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                size: 14,
              ),
            ],
          ),
        ),
        if (_open)
          for (final check in widget.checks)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (check.passed) {
                      true => CupertinoIcons.checkmark_circle,
                      false => CupertinoIcons.xmark_circle,
                      null => CupertinoIcons.info_circle,
                    },
                    size: 16,
                    color: check.passed == false
                        ? AppColors.danger
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${check.question} '
                          '${_answerLabels[check.answer] ?? check.answer}',
                          style: textTheme.bodyMedium,
                        ),
                        if (check.note case final note? when note.isNotEmpty)
                          Text(
                            'Checker\'s note (unchecked): $note',
                            style: textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  static const _answerLabels = {
    'yes': '— Yes',
    'no': '— No',
    'unsure': '— Unsure',
  };
}

class _ImageFrame extends StatelessWidget {
  const _ImageFrame({required this.aspectRatio, required this.child});

  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
        ),
        child: child,
      ),
    );
  }
}

class _NetworkImage extends StatelessWidget {
  const _NetworkImage({super.key, required this.url});

  final Future<String> url;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: url,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const _ImageError();
        final value = snapshot.data;
        if (value == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Image.network(
          value,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _ImageError(),
        );
      },
    );
  }
}

class _ImageError extends StatelessWidget {
  const _ImageError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(
        CupertinoIcons.exclamationmark_triangle,
        color: AppColors.textTertiary,
        size: 28,
      ),
    );
  }
}
