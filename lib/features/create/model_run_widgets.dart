import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// One request to a model and the result of checking its reply, as returned
/// by `analyze_asset` and `build_blueprint`.
@immutable
class ModelAttempt {
  const ModelAttempt({
    required this.passed,
    required this.issues,
    required this.model,
    required this.latencyMs,
    required this.inputTokens,
    required this.outputTokens,
    required this.rawText,
  });

  factory ModelAttempt.fromMap(Map<String, dynamic> map) {
    return ModelAttempt(
      passed: map['status'] == 'passed',
      issues: callableStrings(map['issues']),
      model: map['model'] as String?,
      latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
      inputTokens: (map['inputTokens'] as num?)?.toInt(),
      outputTokens: (map['outputTokens'] as num?)?.toInt(),
      rawText: map['rawText'] as String?,
    );
  }

  static List<ModelAttempt> listFrom(Object? value) => [
    for (final attempt in (value as List? ?? const []))
      ModelAttempt.fromMap(callableMap(attempt)),
  ];

  final bool passed;
  final List<String> issues;
  final String? model;
  final int latencyMs;
  final int? inputTokens;
  final int? outputTokens;

  /// The model's reply exactly as received, before any checks. Null when the
  /// server's inspection switch is off. Never treat this as a result.
  final String? rawText;
}

/// Callable results arrive as `Map<Object?, Object?>` at every level.
Map<String, dynamic> callableMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<String> callableStrings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

/// Turns `snake_case` labels into "Snake case".
String humanize(String value) {
  final words = value.replaceAll('_', ' ').trim();
  return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Passed or failed, with each attempt's time, model and check failures.
class CheckStatusCard extends StatelessWidget {
  const CheckStatusCard({
    super.key,
    required this.attempts,
    required this.passed,
    required this.passedSummary,
    required this.failedSummary,
  });

  final List<ModelAttempt> attempts;
  final bool passed;
  final String passedSummary;
  final String failedSummary;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      key: const Key('check-status'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                passed
                    ? CupertinoIcons.checkmark_seal_fill
                    : CupertinoIcons.xmark_seal_fill,
                color: passed ? AppColors.accent : AppColors.danger,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                passed ? 'Check passed' : 'Check failed',
                style: textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            passed ? passedSummary : failedSummary,
            style: textTheme.bodyMedium,
          ),
          for (final (index, attempt) in attempts.indexed) ...[
            const Divider(height: 24),
            _AttemptSummary(index: index, attempt: attempt),
          ],
        ],
      ),
    );
  }
}

class _AttemptSummary extends StatelessWidget {
  const _AttemptSummary({required this.index, required this.attempt});

  final int index;
  final ModelAttempt attempt;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final details = [
      attempt.passed ? 'Passed' : 'Failed',
      '${(attempt.latencyMs / 1000).toStringAsFixed(1)} s',
      ?attempt.model,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Attempt ${index + 1}',
          style: textTheme.titleMedium?.copyWith(fontSize: 14),
        ),
        const SizedBox(height: 2),
        Text(details, style: textTheme.bodyMedium),
        for (final issue in attempt.issues)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '• $issue',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.danger),
            ),
          ),
      ],
    );
  }
}

/// The model's unchecked replies, for inspection builds only.
class RawOutputPanel extends StatelessWidget {
  const RawOutputPanel({super.key, required this.attempts});

  final List<ModelAttempt> attempts;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      key: const Key('raw-output-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Unchecked raw output'),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            'Exactly what the model replied, before any checks. For '
            'inspection only: it is never used as a result.',
            style: textTheme.bodyMedium,
          ),
        ),
        for (final (index, attempt) in attempts.indexed) ...[
          if (index > 0) const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Attempt ${index + 1} · '
                        '${attempt.passed ? 'passed' : 'failed'} the check',
                        style: textTheme.titleMedium?.copyWith(fontSize: 14),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy raw output',
                      icon: const Icon(CupertinoIcons.doc_on_doc, size: 18),
                      onPressed: () => _copy(context, attempt.rawText ?? ''),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  child: SelectableText(
                    (attempt.rawText ?? '').isEmpty
                        ? '(empty reply)'
                        : attempt.rawText!,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontFamilyFallback: ['RobotoMono', 'monospace'],
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Raw output copied.')));
  }
}

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.fromLTRB(18, 14, 10, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: child,
    );
  }
}

/// Label and value rows in a card, used for asset metadata and the analysis.
class DetailsCard extends StatelessWidget {
  const DetailsCard({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(
        children: [
          for (final (index, (label, value)) in rows.indexed) ...[
            if (index > 0) const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.bodyMedium),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SelectableText(
                      value,
                      textAlign: TextAlign.end,
                      style: textTheme.titleMedium?.copyWith(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
