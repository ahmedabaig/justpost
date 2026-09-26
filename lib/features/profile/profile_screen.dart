import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_screen.dart';
import '../../widgets/pressable.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return AppScreen(
      title: 'You',
      child: ListView(
        padding: EdgeInsets.fromLTRB(24, 4, 24, bottomInset + 8),
        children: [
          const _AccountCard(),
          const SizedBox(height: 26),
          _SettingsGroup(
            rows: [
              _SettingsRow(
                icon: CupertinoIcons.slider_horizontal_3,
                title: 'Settings',
                onTap: () => _announcePending(context, 'Settings'),
              ),
              _SettingsRow(
                icon: CupertinoIcons.question_circle,
                title: 'Help',
                onTap: () => _announcePending(context, 'Help'),
              ),
              _SettingsRow(
                icon: CupertinoIcons.info_circle,
                title: 'About JustPost',
                onTap: () => _announcePending(context, 'About JustPost'),
              ),
            ],
          ),
          const SizedBox(height: 30),
          Center(
            child: Text(
              'JustPost — slideshow variation studio',
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  // These destinations are not built yet; say so rather than leaving a tap that
  // silently does nothing.
  static void _announcePending(BuildContext context, String destination) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$destination is coming soon.')));
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              gradient: AppColors.accentGradient,
              shape: BoxShape.circle,
            ),
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                CupertinoIcons.person_fill,
                color: AppColors.accentBright,
                size: 26,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your account',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Profile details coming next',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// iOS-style inset group: one card, hairline separators, no gaps between rows.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline, width: 0.5),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 62),
                child: Divider(),
              ),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Pressable(
        onTap: onTap,
        scale: 0.985,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accentWash,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 16, color: AppColors.accentBright),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Icon(
                CupertinoIcons.chevron_right,
                size: 15,
                color: AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
