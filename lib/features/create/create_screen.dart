import 'dart:io';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pressable.dart';

class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key, required this.uploadRequests});

  final ValueListenable<int> uploadRequests;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  static const double _thumbWidth = 46;
  static const double _thumbGap = 10;
  static const double _stripHeight = 78;

  final ImagePicker _picker = ImagePicker();
  final PageController _pageController = PageController();
  final ScrollController _stripController = ScrollController();

  List<XFile> _slides = const [];
  int _currentSlide = 0;
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    widget.uploadRequests.addListener(_handleUploadRequest);
  }

  @override
  void didUpdateWidget(CreateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uploadRequests != widget.uploadRequests) {
      oldWidget.uploadRequests.removeListener(_handleUploadRequest);
      widget.uploadRequests.addListener(_handleUploadRequest);
    }
  }

  void _handleUploadRequest() => _pickSlides();

  @override
  void dispose() {
    widget.uploadRequests.removeListener(_handleUploadRequest);
    _pageController.dispose();
    _stripController.dispose();
    super.dispose();
  }

  Future<void> _pickSlides() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      final slides = await _picker.pickMultiImage();
      if (!mounted || slides.isEmpty) return;

      setState(() {
        _slides = slides;
        _currentSlide = 0;
      });
      HapticFeedback.lightImpact();
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      if (_stripController.hasClients) _stripController.jumpTo(0);
    } catch (error, stackTrace) {
      debugPrint('JustPost: pickMultiImage failed — $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'We could not open your photo library. Check photo access in '
            'Settings and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _deleteCurrentSlide() {
    if (_slides.isEmpty) return;

    HapticFeedback.selectionClick();
    final nextSlides = List<XFile>.of(_slides)..removeAt(_currentSlide);
    final nextIndex = nextSlides.isEmpty
        ? 0
        : _currentSlide < nextSlides.length
        ? _currentSlide
        : nextSlides.length - 1;

    setState(() {
      _slides = nextSlides;
      _currentSlide = nextIndex;
    });

    if (nextSlides.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(nextIndex);
        _revealThumbnail(nextIndex);
      });
    }
  }

  Future<void> _replaceCurrentSlide() async {
    if (_isPicking || _slides.isEmpty) return;

    final index = _currentSlide;
    setState(() => _isPicking = true);

    try {
      final replacement = await _picker.pickImage(source: ImageSource.gallery);
      if (!mounted || replacement == null || index >= _slides.length) return;

      final nextSlides = List<XFile>.of(_slides);
      nextSlides[index] = replacement;
      setState(() => _slides = nextSlides);
      HapticFeedback.lightImpact();
    } catch (error, stackTrace) {
      debugPrint('JustPost: replacing slide failed — $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'We could not replace this slide. Check photo access in Settings '
            'and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _selectSlide(int index) {
    _pageController.animateToPage(
      index,
      duration: AppMotion.base,
      curve: AppMotion.enter,
    );
  }

  /// Keeps the tapped or swiped thumbnail centred in the strip.
  void _revealThumbnail(int index) {
    if (!_stripController.hasClients) return;
    final position = _stripController.position;
    final target =
        (_thumbWidth + _thumbGap) * index -
        (position.viewportDimension - _thumbWidth) / 2;
    _stripController.animateTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: AppMotion.base,
      curve: AppMotion.enter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSlides = _slides.isNotEmpty;

    return AppScreen(
      key: const Key('create-screen'),
      child: AnimatedSwitcher(
        duration: AppMotion.slow,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: hasSlides ? _buildSlideshow(context) : _buildEmptyState(context),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return const SizedBox.expand(key: ValueKey('empty'));
  }

  Widget _buildSlideshow(BuildContext context) {
    final count = _slides.length;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Column(
      key: const ValueKey('slideshow'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GlassIconButton(
                icon: CupertinoIcons.trash,
                semanticLabel: 'Delete current slide',
                onPressed: _deleteCurrentSlide,
              ),
              GlassIconButton(
                icon: CupertinoIcons.arrow_2_squarepath,
                semanticLabel: 'Replace current slide',
                onPressed: _isPicking ? null : _replaceCurrentSlide,
              ),
            ],
          ),
        ),
        Expanded(child: _buildPager(count)),
        const SizedBox(height: 18),
        SizedBox(
          height: _stripHeight,
          child: ListView.separated(
            controller: _stripController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: _thumbGap),
            itemBuilder: (context, index) => _SlideThumbnail(
              file: _slides[index],
              index: index,
              width: _thumbWidth,
              selected: index == _currentSlide,
              onTap: () => _selectSlide(index),
            ),
          ),
        ),
        SizedBox(height: bottomInset + 6),
      ],
    );
  }

  Widget _buildPager(int count) {
    return PageView.builder(
      controller: _pageController,
      itemCount: count,
      onPageChanged: (index) {
        setState(() => _currentSlide = index);
        _revealThumbnail(index);
      },
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _pageController,
          builder: (context, child) {
            // Neighbouring slides sit slightly back so the swipe reads as depth.
            var scale = 1.0;
            if (_pageController.hasClients &&
                _pageController.position.haveDimensions) {
              final page = _pageController.page ?? index.toDouble();
              scale = (1 - (page - index).abs() * 0.08).clamp(0.92, 1.0);
            }
            return Transform.scale(scale: scale, child: child);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _SlideFrame(
              file: _slides[index],
              index: index,
              total: count,
            ),
          ),
        );
      },
    );
  }
}

class _SlideFrame extends StatelessWidget {
  const _SlideFrame({
    required this.file,
    required this.index,
    required this.total,
  });

  final XFile file;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
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
              // A heavily downscaled, blurred copy fills the frame so slides
              // that are not 9:16 never show hard letterboxing.
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Image.file(
                  File(file.path),
                  fit: BoxFit.cover,
                  cacheWidth: 48,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x5C000000)),
              ),
              Image.file(
                File(file.path),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(
                    CupertinoIcons.exclamationmark_triangle,
                    color: AppColors.textTertiary,
                    size: 36,
                  ),
                ),
              ),
              Positioned(
                top: 14,
                left: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xA6000000),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: AppColors.hairlineStrong,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    'SLIDE ${index + 1} / $total',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideThumbnail extends StatelessWidget {
  const _SlideThumbnail({
    required this.file,
    required this.index,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final XFile file;
  final int index;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Slide ${index + 1}',
      child: Pressable(
        onTap: onTap,
        scale: 0.93,
        child: AnimatedContainer(
          duration: AppMotion.base,
          curve: AppMotion.enter,
          width: width,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? AppColors.accentBright
                  : AppColors.hairlineStrong,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? const [BoxShadow(color: Color(0x4D1F1717), blurRadius: 16)]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(file.path),
                  fit: BoxFit.cover,
                  cacheWidth: 180,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: AppColors.surfaceRaised),
                ),
                AnimatedOpacity(
                  opacity: selected ? 0 : 0.45,
                  duration: AppMotion.base,
                  child: const ColoredBox(color: AppColors.canvas),
                ),
                Positioned(
                  left: 3,
                  bottom: 3,
                  child: Container(
                    width: 17,
                    height: 17,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xD90A0910),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
