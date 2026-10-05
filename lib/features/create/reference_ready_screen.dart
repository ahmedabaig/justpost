import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/build_flags.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ambient_background.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/buttons.dart';
import 'analysis_result_view.dart';
import 'analysis_service.dart';
import 'asset_service.dart';
import 'blueprint_screen.dart';
import 'blueprint_service.dart';
import 'model_run_widgets.dart';

/// Shows what the backend stored for a reference slide: the original next to
/// the normalized analysis copy, plus the recorded metadata, and runs the
/// creative analysis.
class ReferenceReadyScreen extends StatefulWidget {
  ReferenceReadyScreen({
    super.key,
    required this.asset,
    required this.original,
    required this.service,
    AnalysisService? analysisService,
    BlueprintService? blueprintService,
    this.showInspection = showAiInspection,
  }) : analysisService = analysisService ?? AnalysisService(),
       blueprintService = blueprintService ?? BlueprintService();

  final ReferenceAsset asset;
  final XFile original;
  final AssetService service;
  final AnalysisService analysisService;
  final BlueprintService blueprintService;
  final bool showInspection;

  @override
  State<ReferenceReadyScreen> createState() => _ReferenceReadyScreenState();
}

class _ReferenceReadyScreenState extends State<ReferenceReadyScreen> {
  late final Future<String> _analysisUrl = widget.service.downloadUrl(
    widget.asset.analysisPath,
  );
  AnalysisRun? _run;
  bool _analyzing = false;
  bool _buildingBlueprint = false;

  Future<void> _buildBlueprint() async {
    if (_buildingBlueprint) return;
    setState(() => _buildingBlueprint = true);
    try {
      final run = await widget.blueprintService.build(widget.asset.assetId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BlueprintScreen(
            run: run,
            service: widget.blueprintService,
            showInspection: widget.showInspection,
          ),
        ),
      );
    } on BlueprintException catch (error) {
      _showError(error.message);
    } catch (error) {
      debugPrint('JustPost: blueprint build failed — ${error.runtimeType}');
      _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _buildingBlueprint = false);
    }
  }

  Future<void> _analyze() async {
    if (_analyzing || _buildingBlueprint) return;
    setState(() => _analyzing = true);
    try {
      final run = await widget.analysisService.analyze(widget.asset.assetId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _run = run);
    } on AnalysisException catch (error) {
      _showError(error.message);
    } catch (error) {
      debugPrint('JustPost: analysis failed — ${error.runtimeType}');
      _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      key: const Key('reference-ready-screen'),
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
                  'Reference ready',
                  style: Theme.of(context).textTheme.headlineMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Preview(
                      label: 'Original',
                      child: Image.file(
                        File(widget.original.path),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const _PreviewError(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Preview(
                      label: 'Analysis copy',
                      child: FutureBuilder<String>(
                        future: _analysisUrl,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) return const _PreviewError();
                          final url = snapshot.data;
                          if (url == null) {
                            return const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          }
                          return Image.network(
                            url,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const _PreviewError(),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              DetailsCard(
                rows: [
                  ('Size', '${asset.width} × ${asset.height}'),
                  ('Orientation', _capitalize(asset.orientation)),
                  ('Format', asset.sourceFormat),
                  ('Color profile', asset.colorProfile ?? 'None (sRGB)'),
                  if (asset.exifOrientation != null &&
                      asset.exifOrientation != 1)
                    ('Rotation fixed', 'EXIF ${asset.exifOrientation}'),
                  if (asset.hasAlpha) ('Transparency', 'Kept'),
                  ('File size', _formatBytes(asset.fileSize)),
                  ('Asset ID', asset.assetId),
                ],
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                key: const Key('analyze-slide-button'),
                label: _run == null ? 'Analyze slide' : 'Analyze again',
                icon: CupertinoIcons.wand_stars,
                busy: _analyzing,
                onPressed: _analyze,
              ),
              if (_run case final run?) ...[
                const SizedBox(height: 20),
                AnalysisResultView(
                  run: run,
                  showInspection: widget.showInspection,
                ),
                if (run.passed) ...[
                  const SizedBox(height: 20),
                  PrimaryButton(
                    key: const Key('build-blueprint-button'),
                    label: 'Build blueprint',
                    icon: CupertinoIcons.square_stack_3d_up,
                    busy: _buildingBlueprint,
                    onPressed: _analyzing ? null : _buildBlueprint,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 9 / 16,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
            ),
            child: child,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

class _PreviewError extends StatelessWidget {
  const _PreviewError();

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
