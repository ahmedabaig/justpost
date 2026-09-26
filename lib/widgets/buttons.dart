import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// Gradient call to action. Owns its own busy state so callers never have to
/// swap the button out for a spinner.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;

    return Semantics(
      button: true,
      enabled: enabled,
      child: Pressable(
        onTap: enabled ? onPressed : null,
        scale: 0.975,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.6,
          duration: AppMotion.quick,
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: AppColors.accentGradient,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x4D7C5CFF),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 19, color: Colors.white),
                        const SizedBox(width: 9),
                      ],
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
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

/// Low-emphasis pill for secondary actions sitting next to content.
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      child: Pressable(
        onTap: onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: AppMotion.quick,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: AppColors.fillSubtle,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: AppColors.textPrimary),
                  const SizedBox(width: 7),
                ],
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
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

/// Circular translucent button for header actions.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Pressable(
        onTap: onPressed,
        scale: 0.9,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.fillSubtle,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.hairlineStrong, width: 0.5),
          ),
          child: Icon(icon, size: 19, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}
