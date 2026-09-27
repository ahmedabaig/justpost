import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Colour tokens for the JustPost studio palette.
///
/// Warm, light JustPost palette.
abstract final class AppColors {
  static const canvas = Color(0xFFFFFDF5);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceRaised = Color(0xFFF4EFE6);

  /// Clear frosted chrome that lets the warm page canvas show through.
  static const glass = Color(0x33FFFFFF);

  static const hairline = Color(0x140F0D14);
  static const hairlineStrong = Color(0x240F0D14);
  static const fillSubtle = Color(0x0F0F0D14);

  static const textPrimary = Color(0xFF1C1922);
  static const textSecondary = Color(0xFF68616F);
  static const textTertiary = Color(0xFF918A97);

  static const accent = Color(0xFF1F1717);
  static const accentBright = Color(0xFF1F1717);
  static const accentWash = Color(0x171F1717);
  static const danger = Color(0xFFD94B65);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3A2B2B), Color(0xFF1F1717)],
  );
}

abstract final class AppRadius {
  static const double control = 18;
  static const double card = 24;
  static const double frame = 28;
  static const double pill = 999;
}

abstract final class AppMotion {
  static const Duration quick = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 360);
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
}

ThemeData buildJustPostTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: Colors.white,
        surface: AppColors.canvas,
        onSurface: AppColors.textPrimary,
        surfaceContainerHighest: AppColors.surfaceRaised,
        error: AppColors.danger,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    canvasColor: AppColors.canvas,
    cupertinoOverrideTheme: const CupertinoThemeData(
      brightness: Brightness.light,
    ),
    iconTheme: const IconThemeData(color: AppColors.textSecondary),
    dividerTheme: const DividerThemeData(
      color: AppColors.hairline,
      thickness: 0.5,
      space: 0.5,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accentBright,
    ),
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 31,
        height: 1.12,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.1,
      ),
      headlineMedium: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 26,
        height: 1.15,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
      ),
      headlineSmall: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleMedium: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 15.5,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      bodyLarge: TextStyle(
        color: AppColors.textSecondary,
        fontSize: 15,
        height: 1.5,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: TextStyle(
        color: AppColors.textSecondary,
        fontSize: 13.5,
        height: 1.4,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: TextStyle(
        color: AppColors.textTertiary,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelSmall: TextStyle(
        color: AppColors.textTertiary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
    // Floating snack bars clear the navigation pill instead of hiding behind it.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF25212D),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 13.5,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      insetPadding: const EdgeInsets.fromLTRB(20, 12, 20, 112),
      elevation: 10,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentBright,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
