import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppColors.accentGradient,
        borderRadius: BorderRadius.circular(size * 0.31),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.42),
            blurRadius: size * 0.55,
            offset: Offset(0, size * 0.18),
          ),
        ],
      ),
      child: Icon(
        CupertinoIcons.sparkles,
        color: Colors.white,
        size: size * 0.52,
      ),
    );
  }
}

class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BrandMark(),
        const SizedBox(width: 11),
        Text('JustPost', style: Theme.of(context).textTheme.headlineSmall),
      ],
    );
  }
}
