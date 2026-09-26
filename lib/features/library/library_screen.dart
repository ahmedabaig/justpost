import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return AppScreen(
      title: 'Library',
      child: CenteredScrollBody(
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
      ),
    );
  }
}
