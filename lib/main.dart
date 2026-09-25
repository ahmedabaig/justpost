import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const JustPostApp());
}

class JustPostApp extends StatelessWidget {
  const JustPostApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF17151D);
    const violet = Color(0xFF6E56CF);

    return MaterialApp(
      title: 'JustPost',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.light,
          surface: const Color(0xFFF8F7FB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8F7FB),
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            color: ink,
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -1.2,
          ),
          headlineSmall: TextStyle(
            color: ink,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w700),
          bodyLarge: TextStyle(color: Color(0xFF5F5A68), height: 1.45),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: ink,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      home: const SlideshowUploadScreen(),
    );
  }
}

class SlideshowUploadScreen extends StatefulWidget {
  const SlideshowUploadScreen({super.key});

  @override
  State<SlideshowUploadScreen> createState() => _SlideshowUploadScreenState();
}

class _SlideshowUploadScreenState extends State<SlideshowUploadScreen> {
  final ImagePicker _picker = ImagePicker();
  final PageController _pageController = PageController();
  List<XFile> _slides = const [];
  int _currentSlide = 0;
  bool _isPicking = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _pickSlideshow() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      final slides = await _picker.pickMultiImage();
      if (!mounted || slides.isEmpty) return;

      setState(() {
        _slides = slides;
        _currentSlide = 0;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open your photo library: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _showSlide(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _clearSlideshow() {
    setState(() {
      _slides = const [];
      _currentSlide = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: const _Brand(),
        actions: [
          if (_slides.isNotEmpty)
            IconButton(
              tooltip: 'Remove slideshow',
              onPressed: _clearSlideshow,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _slides.isEmpty ? _buildEmptyState() : _buildSlideshow(),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      key: const ValueKey('empty'),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFEDE8FF),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'CONTROLLED CREATIVE VARIATIONS',
              style: TextStyle(
                color: Color(0xFF5B43B9),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.7,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'More versions.\nSame winning idea.',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 16),
          Text(
            'Upload a slideshow that already performs. JustPost will help you '
            'create new versions without losing what made it work.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 34),
          _UploadCard(onTap: _pickSlideshow, loading: _isPicking),
          const SizedBox(height: 20),
          const _OrderHint(),
        ],
      ),
    );
  }

  Widget _buildSlideshow() {
    final slideCount = _slides.length;
    return Column(
      key: const ValueKey('slideshow'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Winning slideshow',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$slideCount ${slideCount == 1 ? 'slide' : 'slides'} uploaded',
                      style: const TextStyle(color: Color(0xFF77717F)),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _isPicking ? null : _pickSlideshow,
                icon: const Icon(Icons.swap_horiz_rounded, size: 19),
                label: const Text('Replace'),
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: slideCount,
            onPageChanged: (index) => setState(() => _currentSlide = index),
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _SlideFrame(
                  file: _slides[index],
                  index: index,
                  total: slideCount,
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 0, 14),
          child: SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: slideCount,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                return _SlideThumbnail(
                  file: _slides[index],
                  index: index,
                  selected: index == _currentSlide,
                  onTap: () => _showSlide(index),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF5B43B9),
                size: 20,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Slides are kept in the order you selected them.',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: const Color(0xFF6D6675)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BrandMark(),
        SizedBox(width: 10),
        Text(
          'JustPost',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        ),
      ],
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8B73F6), Color(0xFF5B43B9)],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(
        Icons.auto_awesome_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.onTap, required this.loading});

  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFE6E2EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D17151D),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: const Color(0xFFF0ECFF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.collections_rounded,
              color: Color(0xFF654CC5),
              size: 30,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Choose your winning slideshow',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 7),
          const Text(
            'Select every image in the order it appears in your post.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF77717F), height: 1.4),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: loading ? null : onTap,
            icon: loading
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add_photo_alternate_outlined),
            label: Text(loading ? 'Opening photos…' : 'Upload slideshow'),
          ),
        ],
      ),
    );
  }
}

class _OrderHint extends StatelessWidget {
  const _OrderHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E8),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline_rounded, color: Color(0xFF9A6A12)),
          SizedBox(width: 11),
          Expanded(
            child: Text(
              'Tip: tap the slides in posting order so JustPost understands '
              'the hook, sequence, and payoff.',
              style: TextStyle(
                color: Color(0xFF73551D),
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
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
            color: const Color(0xFF24212A),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2917151D),
                blurRadius: 28,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(file.path),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 42,
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC17151D),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'SLIDE ${index + 1} OF $total',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
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
    required this.selected,
    required this.onTap,
  });

  final XFile file;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 54,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF6E56CF) : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? const Color(0xFF6E56CF) : const Color(0xFFDCD7E2),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(File(file.path), fit: BoxFit.cover),
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  width: 19,
                  height: 19,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xD917151D),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
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
