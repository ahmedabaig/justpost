import 'dart:io';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/brand.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pressable.dart';

class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key});

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
  void dispose() {
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

  void _clearSlides() {
    HapticFeedback.selectionClick();
    setState(() {
      _slides = const [];
      _currentSlide = 0;
    });
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
      leading: const BrandLockup(),
      actions: [
        if (hasSlides)
          GlassIconButton(
            icon: CupertinoIcons.trash,
            semanticLabel: 'Remove slideshow',
            onPressed: _clearSlides,
          ),
      ],
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
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return CenteredScrollBody(
      key: const ValueKey('empty'),
      padding: EdgeInsets.fromLTRB(28, 4, 28, bottomInset + 4),
      children: [
        const _SlideshowGlyph(),
        const SizedBox(height: 38),
        Text(
          'Start with something\nworth repeating.',
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall,
        ),
        const SizedBox(height: 14),
        Text(
          'Pick the slides from a post that already worked. JustPost keeps them '
          'in the exact order you choose.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 34),
        SizedBox(
          width: double.infinity,
          child: PrimaryButton(
            label: 'Choose slides',
            icon: CupertinoIcons.photo_on_rectangle,
            busy: _isPicking,
            onPressed: _pickSlides,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Tap them in posting order — hook first, payoff last.',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium,
        ),
      ],
    );
  }

  Widget _buildSlideshow(BuildContext context) {
    final theme = Theme.of(context);
    final count = _slides.length;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Column(
      key: const ValueKey('slideshow'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count ${count == 1 ? 'slide' : 'slides'} ready',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        const Icon(
                          CupertinoIcons.checkmark_seal_fill,
                          size: 14,
                          color: AppColors.accentBright,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Posting order preserved',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GhostButton(
                label: 'Replace',
                icon: CupertinoIcons.arrow_2_squarepath,
                onPressed: _isPicking ? null : _pickSlides,
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
                ? const [BoxShadow(color: Color(0x4D7C5CFF), blurRadius: 16)]
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

/// Stack-of-slides illustration used on the empty Create screen.
class _SlideshowGlyph extends StatelessWidget {
  const _SlideshowGlyph();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 152,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.rotate(
            angle: -0.13,
            child: const _GlyphCard(color: Color(0x14FFFFFF)),
          ),
          Transform.translate(
            offset: const Offset(19, 3),
            child: Transform.rotate(
              angle: 0.1,
              child: const _GlyphCard(color: Color(0x2E7C5CFF)),
            ),
          ),
          Container(
            width: 98,
            height: 138,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF241F33), Color(0xFF14121C)],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x73000000),
                  blurRadius: 30,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: const Icon(
              CupertinoIcons.sparkles,
              color: AppColors.accentBright,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlyphCard extends StatelessWidget {
  const _GlyphCard({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 130,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
    );
  }
}
