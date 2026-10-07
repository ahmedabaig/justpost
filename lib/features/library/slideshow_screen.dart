import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import '../create/create_steps.dart';
import '../create/model_run_widgets.dart';
import 'slideshow_service.dart';

/// One reference's final set. With passed slides from the current plans, you
/// tick and order them and save the set; the saved set can then be saved to
/// Photos or shared as the same PNGs shown here. Without current passed
/// slides, the saved set is shown as it is.
class SlideshowScreen extends StatefulWidget {
  const SlideshowScreen({
    super.key,
    required this.assetId,
    required this.service,
    this.exporter,
    this.showSteps = false,
  });

  final String assetId;
  final SlideshowService service;
  final SlideExporter? exporter;

  /// Opened from the Create flow, whose earlier steps are still open.
  final bool showSteps;

  @override
  State<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends State<SlideshowScreen> {
  late final SlideExporter _exporter = widget.exporter ?? SlideExporter();
  final Map<String, Future<String>> _urls = {};

  Slideshow? _show;
  String? _loadError;

  /// Plan IDs of the passed slides, in the order chosen.
  List<String> _order = const [];
  Set<String> _included = const {};
  FinalSet? _saved;

  bool _saving = false;
  String? _saveError;
  bool _exporting = false;
  String? _exportMessage;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _show = null;
    });
    try {
      final show = await widget.service.get(widget.assetId);
      if (!mounted) return;
      final passed = {for (final slide in show.passedSlides) slide.planId};
      final saved = [
        for (final slide in show.finalSet?.slides ?? const <SetSlide>[])
          if (passed.contains(slide.planId)) slide.planId,
      ];
      setState(() {
        _show = show;
        _saved = show.finalSet;
        // A saved set comes first, in its order; otherwise every passed
        // slide is in, in plan order.
        _order = [...saved, ...passed.where((id) => !saved.contains(id))];
        _included = saved.isEmpty ? passed : saved.toSet();
      });
    } on SlideshowException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    } catch (error) {
      debugPrint(
        'JustPost: loading the slideshow failed — ${error.runtimeType}',
      );
      if (mounted) {
        setState(() => _loadError = 'Something went wrong. Please try again.');
      }
    }
  }

  Future<String> _url(String path) =>
      _urls[path] ??= (widget.service.downloadUrl(path)..ignore());

  Map<String, SetSlide> get _passed => {
    for (final slide in _show?.passedSlides ?? const <SetSlide>[])
      slide.planId: slide,
  };

  List<String> get _selection => [
    for (final id in _order)
      if (_included.contains(id)) id,
  ];

  /// True when the ticked slides, their order and their files match the
  /// saved set, so exporting gives exactly what's on screen.
  bool get _savedMatches {
    final saved = _saved;
    final selection = _selection;
    final passed = _passed;
    if (saved == null || saved.slides.length != selection.length) return false;
    for (final (index, slide) in saved.slides.indexed) {
      if (slide.planId != selection[index] ||
          slide.imagePath != passed[slide.planId]?.imagePath) {
        return false;
      }
    }
    return true;
  }

  bool get _editable => _show?.passedSlides.isNotEmpty ?? false;

  /// The saved slides that can be exported now, or null.
  List<SetSlide>? get _exportable {
    final slides = _saved?.slides ?? const <SetSlide>[];
    if (slides.isEmpty || (_editable && !_savedMatches)) return null;
    return slides;
  }

  void _clearMessages() {
    _saveError = null;
    _exportMessage = null;
    _exportError = null;
  }

  void _toggle(String planId) {
    if (_saving) return;
    setState(() {
      _clearMessages();
      _included = {..._included};
      if (!_included.remove(planId)) _included.add(planId);
    });
  }

  void _move(String planId, int by) {
    final from = _order.indexOf(planId);
    final to = from + by;
    if (_saving || from < 0 || to < 0 || to >= _order.length) return;
    HapticFeedback.selectionClick();
    setState(() {
      _clearMessages();
      _order = [..._order]
        ..removeAt(from)
        ..insert(to, planId);
    });
  }

  Future<void> _save() async {
    final selection = _selection;
    if (_saving || selection.isEmpty) return;
    setState(() {
      _clearMessages();
      _saving = true;
    });
    String? error;
    FinalSet? saved;
    try {
      saved = await widget.service.saveSet(widget.assetId, selection);
      HapticFeedback.lightImpact();
    } on SlideshowException catch (exception) {
      error = exception.message;
    } catch (exception) {
      debugPrint('JustPost: saving the set failed — ${exception.runtimeType}');
      error = 'Something went wrong. Please try again.';
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveError = error;
      _saved = saved ?? _saved;
    });
  }

  Future<void> _export({required bool toPhotos, Rect? origin}) async {
    final slides = _exportable;
    if (_exporting || slides == null) return;
    setState(() {
      _clearMessages();
      _exporting = true;
    });
    String? message;
    String? error;
    try {
      final files = await Future.wait([
        for (final slide in slides) widget.service.download(slide.imagePath),
      ]);
      if (toPhotos) {
        await _exporter.saveToPhotos(files);
        message = files.length == 1
            ? 'Saved 1 slide to Photos.'
            : 'Saved ${files.length} slides to Photos.';
        HapticFeedback.lightImpact();
      } else {
        await _exporter.share(files, origin: origin);
      }
    } on SlideshowException catch (exception) {
      error = exception.message;
    } catch (exception) {
      debugPrint(
        'JustPost: exporting slides failed — ${exception.runtimeType}',
      );
      error = toPhotos
          ? 'Saving to Photos failed. Please try again.'
          : 'Sharing failed. Please try again.';
    }
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _exportMessage = message;
      _exportError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('slideshow-screen'),
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
                  'Final set',
                  style: Theme.of(context).textTheme.headlineMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final show = _show;
    final loadError = _loadError;

    if (loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loadError,
              key: const Key('slideshow-error'),
              style: textTheme.bodyMedium?.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: 12),
            GhostButton(
              label: 'Try again',
              icon: CupertinoIcons.arrow_clockwise,
              onPressed: _load,
            ),
          ],
        ),
      );
    }
    if (show == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final passed = _passed;
    final savedSlides = _saved?.slides ?? const <SetSlide>[];

    return ListView(
      padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
      children: [
        if (widget.showSteps) ...[
          const CreateStepBar(current: CreateStep.set),
          const SizedBox(height: 12),
        ],
        if (_editable) ...[
          Text(
            'Tick the slides for your set and put them in order. Only '
            'slides that passed their checks are here.',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          for (final (index, planId) in _order.indexed)
            if (passed[planId] case final slide?)
              _SlideRow(
                key: Key('set-slide-$planId'),
                slide: slide,
                url: _url(slide.imagePath),
                position: _included.contains(planId)
                    ? _selection.indexOf(planId) + 1
                    : null,
                onToggle: () => _toggle(planId),
                onUp: index > 0 ? () => _move(planId, -1) : null,
                onDown: index < _order.length - 1
                    ? () => _move(planId, 1)
                    : null,
              ),
          const SizedBox(height: 8),
          PrimaryButton(
            key: const Key('save-set'),
            label: _savedMatches ? 'Set saved' : 'Save set',
            icon: _savedMatches
                ? CupertinoIcons.checkmark_alt
                : CupertinoIcons.tray_arrow_down,
            busy: _saving,
            onPressed: _selection.isEmpty || _savedMatches || _saving
                ? null
                : _save,
          ),
          if (_selection.isEmpty)
            _Note('Tick at least one slide.', key: const Key('set-empty')),
          if (_saveError case final error?)
            _Note(error, danger: true, key: const Key('save-set-error')),
        ] else if (savedSlides.isNotEmpty) ...[
          Text('Your saved set, in order.', style: textTheme.bodyMedium),
          const SizedBox(height: 16),
          for (final (index, slide) in savedSlides.indexed)
            _SlideRow(
              key: Key('set-slide-${slide.planId}'),
              slide: slide,
              url: _url(slide.imagePath),
              position: index + 1,
            ),
        ] else
          Text(
            'No slides have passed their checks yet. Make slides from the '
            'Create tab, then save a set.',
            key: const Key('slideshow-empty'),
            style: textTheme.bodyMedium,
          ),
        if (_exportable != null) ...[
          const SizedBox(height: 20),
          const SectionTitle('Export'),
          PrimaryButton(
            key: const Key('save-photos'),
            label: 'Save to Photos',
            icon: CupertinoIcons.photo_on_rectangle,
            busy: _exporting,
            onPressed: _exporting ? null : () => _export(toPhotos: true),
          ),
          const SizedBox(height: 10),
          Builder(
            builder: (buttonContext) => GhostButton(
              key: const Key('share-set'),
              label: 'Share',
              icon: CupertinoIcons.share,
              onPressed: _exporting
                  ? null
                  : () => _export(
                      toPhotos: false,
                      origin: _originOf(buttonContext),
                    ),
            ),
          ),
        ] else if (_editable && savedSlides.isNotEmpty)
          _Note(
            'You changed the set. Save it again to export it.',
            key: const Key('set-changed'),
          ),
        if (_exportMessage case final message?)
          _Note(message, key: const Key('export-message')),
        if (_exportError case final error?)
          _Note(error, danger: true, key: const Key('export-error')),
      ],
    );
  }

  static Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: danger ? style?.copyWith(color: AppColors.danger) : style,
      ),
    );
  }
}

/// A slide thumbnail with its plan; tickable and movable when the callbacks
/// are given.
class _SlideRow extends StatelessWidget {
  const _SlideRow({
    super.key,
    required this.slide,
    required this.url,
    required this.position,
    this.onToggle,
    this.onUp,
    this.onDown,
  });

  final SetSlide slide;
  final Future<String> url;

  /// The slide's place in the set, or null when it isn't in it.
  final int? position;
  final VoidCallback? onToggle;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final title = slide.title?.isNotEmpty == true ? slide.title! : 'Slide';
    final width = slide.width;
    final height = slide.height;
    final toggle = onToggle;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: AspectRatio(
                aspectRatio: width != null && height != null && height > 0
                    ? width / height
                    : 9 / 16,
                child: StorageImage(url: url),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    position == null ? 'Not in the set' : 'Slide $position',
                    style: textTheme.labelSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (slide.number case final number?) 'Plan $number',
                      title,
                    ].join(' · '),
                    style: textTheme.titleMedium?.copyWith(fontSize: 14),
                  ),
                  if (slide.text case final text? when text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
            if (toggle != null)
              Column(
                children: [
                  Checkbox(
                    key: Key('include-${slide.planId}'),
                    value: position != null,
                    onChanged: (_) => toggle(),
                  ),
                  IconButton(
                    key: Key('up-${slide.planId}'),
                    tooltip: 'Move up',
                    icon: const Icon(CupertinoIcons.chevron_up, size: 18),
                    onPressed: onUp,
                  ),
                  IconButton(
                    key: Key('down-${slide.planId}'),
                    tooltip: 'Move down',
                    icon: const Icon(CupertinoIcons.chevron_down, size: 18),
                    onPressed: onDown,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// An image from Storage, shown once its download URL arrives.
class StorageImage extends StatelessWidget {
  const StorageImage({super.key, required this.url});

  final Future<String> url;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
      ),
      child: FutureBuilder<String>(
        future: url,
        builder: (context, snapshot) {
          final value = snapshot.data;
          if (snapshot.hasError) return const _ImageError();
          if (value == null) {
            return const Center(
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Image.network(
            value,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const _ImageError(),
          );
        },
      ),
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
        size: 20,
      ),
    );
  }
}
