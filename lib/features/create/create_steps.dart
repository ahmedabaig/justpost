import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The Create flow's screens, in order. Each is pushed on top of the one
/// before, so every earlier step is still in the navigator.
enum CreateStep {
  reference('Reference'),
  blueprint('Blueprint'),
  plans('Plans'),
  images('Images'),
  set('Set');

  const CreateStep(this.label);

  final String label;

  String get routeName => 'create/$name';

  /// A route for this step's screen, so the step bar can find it again.
  MaterialPageRoute<T> route<T>(WidgetBuilder builder) => MaterialPageRoute<T>(
    settings: RouteSettings(name: routeName),
    builder: builder,
  );

  /// Goes back to this step's screen, closing every screen above it.
  void popTo(BuildContext context) {
    Navigator.of(context)
        .popUntil((route) => route.settings.name == routeName || route.isFirst);
  }
}

/// Where you are in the Create flow. Earlier steps can be tapped to go back
/// to them; later ones can't be reached from here.
class CreateStepBar extends StatelessWidget {
  const CreateStepBar({super.key, required this.current});

  final CreateStep current;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final step in CreateStep.values) ...[
            if (step != CreateStep.values.first)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  CupertinoIcons.chevron_right,
                  size: 10,
                  color: AppColors.textTertiary,
                ),
              ),
            _StepChip(
              key: Key('step-${step.name}'),
              label: step.label,
              current: step == current,
              style: style,
              onTap: step.index < current.index
                  ? () => step.popTo(context)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    super.key,
    required this.label,
    required this.current,
    required this.style,
    required this.onTap,
  });

  final String label;
  final bool current;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tappable = onTap != null;
    final color = current
        ? AppColors.textPrimary
        : tappable
        ? AppColors.textSecondary
        : AppColors.textTertiary;

    return Semantics(
      button: tappable,
      selected: current,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: current
              ? BoxDecoration(
                  color: AppColors.fillSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                )
              : null,
          child: Text(
            label,
            style: style?.copyWith(
              color: color,
              decoration: tappable ? TextDecoration.underline : null,
              decorationColor: color,
            ),
          ),
        ),
      ),
    );
  }
}
