import 'package:flutter/material.dart';

import 'analysis_service.dart';
import 'model_run_widgets.dart';

/// The result of an analysis run: the check status, the checked analysis when
/// one passed, and, for inspection builds only, the unchecked raw replies.
class AnalysisResultView extends StatelessWidget {
  const AnalysisResultView({
    super.key,
    required this.run,
    required this.showInspection,
  });

  final AnalysisRun run;
  final bool showInspection;

  @override
  Widget build(BuildContext context) {
    final analysis = run.analysis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckStatusCard(
          attempts: run.attempts,
          passed: run.passed,
          passedSummary:
              'Passed on attempt ${run.attempts.length}. Only this checked '
              'version is saved for later steps.',
          failedSummary:
              'No attempt passed, so nothing was saved for later steps.',
        ),
        if (analysis != null) ...[
          const SizedBox(height: 20),
          const SectionTitle('What the slide is doing'),
          DetailsCard(
            key: const Key('checked-analysis'),
            rows: [
              ('Creative type', humanize(analysis.creativeType)),
              if (analysis.hookType != null) ('Hook', analysis.hookType!),
              if (analysis.mechanisms.isNotEmpty)
                ('Why it grabs attention', analysis.mechanisms.join('\n')),
              ('Scene', analysis.scene),
              ('Camera', analysis.cameraStyle),
              if (analysis.subjects.isNotEmpty)
                ('Subjects', analysis.subjects.join('\n')),
              if (analysis.visualDevices.isNotEmpty)
                ('Visual devices', analysis.visualDevices.join('\n')),
              for (final block in analysis.slideText)
                ('Text (${humanize(block.role)})', block.text),
              if (analysis.visualHierarchy.isNotEmpty)
                ('Eye goes to', analysis.visualHierarchy.join(', then ')),
              ('Aesthetic', analysis.aesthetic.join(', ')),
              ('Central elements', analysis.centralElements.join('\n')),
            ],
          ),
        ],
        if (showInspection && run.rawExposed) ...[
          const SizedBox(height: 20),
          RawOutputPanel(attempts: run.attempts),
        ],
      ],
    );
  }
}
