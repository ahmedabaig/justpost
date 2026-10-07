import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_screen.dart';
import '../create/model_run_widgets.dart';
import 'slideshow_screen.dart';
import 'slideshow_service.dart';

/// Every reference you've worked on, newest first. It loads when the tab is
/// opened ([refreshRequests]) and on pull to refresh; a card opens its set.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.service,
    this.exporter,
    this.refreshRequests,
  });

  final SlideshowService? service;
  final SlideExporter? exporter;
  final Listenable? refreshRequests;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final SlideshowService _service = widget.service ?? SlideshowService();
  final Map<String, Future<String>> _urls = {};

  List<SlideshowSummary>? _slideshows;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.refreshRequests?.addListener(_load);
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshRequests != widget.refreshRequests) {
      oldWidget.refreshRequests?.removeListener(_load);
      widget.refreshRequests?.addListener(_load);
    }
  }

  @override
  void dispose() {
    widget.refreshRequests?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    List<SlideshowSummary>? slideshows;
    String? error;
    try {
      slideshows = await _service.list();
    } on SlideshowException catch (exception) {
      error = exception.message;
    } catch (exception) {
      debugPrint(
        'JustPost: loading the Library failed — ${exception.runtimeType}',
      );
      error = 'Something went wrong. Please try again.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      _slideshows = slideshows ?? _slideshows;
    });
  }

  Future<String> _url(String path) =>
      _urls[path] ??= (_service.downloadUrl(path)..ignore());

  Future<void> _open(SlideshowSummary slideshow) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SlideshowScreen(
          assetId: slideshow.assetId,
          service: _service,
          exporter: widget.exporter,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final slideshows = _slideshows ?? const <SlideshowSummary>[];
    final error = _error;

    if (slideshows.isEmpty && error == null) {
      return AppScreen(
        title: 'Library',
        child: _loading
            ? const Center(
                key: Key('library-loading'),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: _EmptyLibrary(bottomInset: bottomInset),
              ),
      );
    }

    return AppScreen(
      title: 'Library',
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error,
                  key: const Key('library-error'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: AppColors.danger),
                ),
              ),
            for (final slideshow in slideshows)
              _SlideshowCard(
                key: Key('library-${slideshow.assetId}'),
                slideshow: slideshow,
                url: switch (slideshow.referencePath) {
                  final path? => _url(path),
                  null => null,
                },
                onTap: () => _open(slideshow),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CenteredScrollBody(
      key: const Key('library-empty'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(28, 4, 28, bottomInset + 4),
      children: [
        Container(
          width: 74,
          height: 74,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accentWash,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
          ),
          child: const Icon(
            CupertinoIcons.square_stack_3d_down_right,
            color: AppColors.accentBright,
            size: 31,
          ),
        ),
        const SizedBox(height: 26),
        Text(
          'Your slideshows will live here',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(
          'Every slideshow you upload stays grouped with the variations '
          'generated from it, so you can compare them side by side.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }
}

class _SlideshowCard extends StatelessWidget {
  const _SlideshowCard({
    super.key,
    required this.slideshow,
    required this.url,
    required this.onTap,
  });

  final SlideshowSummary slideshow;
  final Future<String>? url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final date = slideshow.updatedAt ?? slideshow.createdAt;
    final url = this.url;
    final counts = [
      if (slideshow.setSize > 0)
        slideshow.setSize == 1
            ? '1 slide in the set'
            : '${slideshow.setSize} slides in the set',
      if (slideshow.passedSlides > 0) '${slideshow.passedSlides} passed',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AppCard(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: url == null
                      ? const DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.surfaceRaised,
                          ),
                        )
                      : StorageImage(url: url),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slideshow.stage.label,
                      style: textTheme.titleMedium?.copyWith(fontSize: 15),
                    ),
                    if (date != null)
                      Text(formatDay(date), style: textTheme.bodyMedium),
                    if (counts.isNotEmpty)
                      Text(counts, style: textTheme.labelSmall),
                  ],
                ),
              ),
              const Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "6 Oct 2026", in local time.
String formatDay(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = date.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
