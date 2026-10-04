import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/buttons.dart';
import 'variation_service.dart';

/// Runs one variation job and shows each slide's result beside its original.
class VariationResultScreen extends StatefulWidget {
  const VariationResultScreen({
    super.key,
    required this.jobId,
    required this.originals,
    required this.service,
  });

  final String jobId;
  final List<XFile> originals;
  final VariationService service;

  @override
  State<VariationResultScreen> createState() => _VariationResultScreenState();
}

class _VariationResultScreenState extends State<VariationResultScreen> {
  final PageController _pageController = PageController();
  final Map<String, Future<String>> _urls = {};
  StreamSubscription<VariationJob?>? _subscription;

  VariationJob? _job;
  String? _startError;
  int _currentSlide = 0;
  bool _showOriginal = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service
        .watch(widget.jobId)
        .listen(
          (job) => setState(() => _job = job),
          onError: (Object error) {
            debugPrint('JustPost: watching job failed — $error');
            setState(() => _startError = 'Lost connection to this job.');
          },
        );
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.service.run(widget.jobId);
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: create_variation ${error.code} — ${error.message}');
      // A dropped connection does not stop the function; keep watching
      // Firestore unless the job never started.
      if (!mounted || _job != null) return;
      setState(() => _startError = _messageFor(error));
    } catch (error) {
      debugPrint('JustPost: create_variation failed — $error');
      if (!mounted || _job != null) return;
      setState(() => _startError = 'Could not start generation.');
    }
  }

  String _messageFor(FirebaseFunctionsException error) {
    final detail = kDebugMode ? ' (${error.code})' : '';
    return switch (error.code) {
      'unauthenticated' =>
        'This build is not verified by App Check yet.$detail',
      'invalid-argument' => '${error.message ?? 'Invalid slides.'}$detail',
      _ => 'Could not start generation.$detail',
    };
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  VariationSlide? _resultFor(int index) {
    final slideId = 'slide${(index + 1).toString().padLeft(2, '0')}';
    for (final slide in _job?.slides ?? const <VariationSlide>[]) {
      if (slide.slideId == slideId) return slide;
    }
    return null;
  }

  Future<String> _urlFor(VariationSlide slide) => _urls.putIfAbsent(
    slide.outputPath,
    () => widget.service.downloadUrl(slide.outputPath),
  );

  String get _statusLine {
    final job = _job;
    final error = job?.status == VariationStatus.failed
        ? job?.error ?? 'Generation failed.'
        : _startError;
    if (error != null) return error;
    if (job == null) return 'Starting…';
    return switch (job.status) {
      VariationStatus.analyzing => 'Analyzing your slideshow…',
      VariationStatus.generating =>
        'Generating slide ${job.completedSlides + 1} of ${job.slideCount}…',
      VariationStatus.done => _doneSummary(job),
      VariationStatus.failed => job.error ?? 'Generation failed.',
    };
  }

  String _doneSummary(VariationJob job) {
    final edited = job.slides.where((slide) => slide.edited).length;
    return 'Done — $edited of ${job.slideCount} slides changed.';
  }

  bool get _failed =>
      _job?.status == VariationStatus.failed ||
      (_startError != null && _job == null);

  @override
  Widget build(BuildContext context) {
    final count = widget.originals.length;
    final result = _resultFor(_currentSlide);
    final running = !_failed && _job?.status != VariationStatus.done;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: AmbientBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: CupertinoIcons.chevron_left,
                      semanticLabel: 'Back',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Variation',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    if (running)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 14),
                child: Text(
                  _statusLine,
                  key: const Key('variation-status'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: _failed ? AppColors.danger : null),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: count,
                  onPageChanged: (index) =>
                      setState(() => _currentSlide = index),
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _ResultFrame(
                      original: widget.originals[index],
                      result: _resultFor(index),
                      showOriginal: _showOriginal,
                      urlFor: _urlFor,
                      pending: running,
                      label: 'SLIDE ${index + 1} / $count',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                child: SizedBox(
                  height: 40,
                  child: Text(
                    result?.keptOriginalReason ?? '',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
                child: CupertinoSlidingSegmentedControl<bool>(
                  groupValue: _showOriginal,
                  onValueChanged: (value) =>
                      setState(() => _showOriginal = value ?? false),
                  children: const {
                    false: Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Variation'),
                    ),
                    true: Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Original'),
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultFrame extends StatelessWidget {
  const _ResultFrame({
    required this.original,
    required this.result,
    required this.showOriginal,
    required this.urlFor,
    required this.pending,
    required this.label,
  });

  final XFile original;
  final VariationSlide? result;
  final bool showOriginal;
  final Future<String> Function(VariationSlide slide) urlFor;
  final bool pending;
  final String label;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final originalImage = Image.file(
      File(original.path),
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );

    Widget body;
    if (showOriginal || result == null) {
      body = originalImage;
    } else {
      body = FutureBuilder<String>(
        future: urlFor(result),
        builder: (context, snapshot) {
          final url = snapshot.data;
          if (url == null) return originalImage;
          return Image.network(
            url,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : originalImage,
            errorBuilder: (_, _, _) => originalImage,
          );
        },
      );
    }

    final String? badge;
    if (showOriginal) {
      badge = 'ORIGINAL';
    } else if (result == null) {
      badge = pending ? 'GENERATING' : null;
    } else {
      badge = result.edited ? 'VARIATION' : 'ORIGINAL KEPT';
    }

    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.frame),
            border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 36,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF15131A)),
              AnimatedSwitcher(duration: AppMotion.base, child: body),
              if (!showOriginal && result == null && pending)
                const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
              Positioned(top: 14, left: 14, child: _Pill(text: label)),
              if (badge != null)
                Positioned(top: 14, right: 14, child: _Pill(text: badge)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xA6000000),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
