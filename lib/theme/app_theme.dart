import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Colour tokens for the JustPost studio palette.
///
/// JustPost is dark-first on purpose: slides are the hero content, so a deep
/// canvas keeps imagery and the translucent chrome reading as one surface.
abstract final class AppColors {
  static const canvas = Color(0xFF0A0910);
  static const surface = Color(0xFF16141E);
  static const surfaceRaised = Color(0xFF1E1B29);

  /// Fill for blurred chrome. Kept translucent so the ambient glow shows.
  static const glass = Color(0xAD15131E);

  static const hairline = Color(0x14FFFFFF);
  static const hairlineStrong = Color(0x26FFFFFF);
  static const fillSubtle = Color(0x14FFFFFF);

  static const textPrimary = Color(0xFFF4F2F8);
  static const textSecondary = Color(0xFFA7A2B4);
  static const textTertiary = Color(0xFF6B6678);

  static const accent = Color(0xFF7C5CFF);
  static const accentBright = Color(0xFFB4A2FF);
  static const accentWash = Color(0x1F7C5CFF);
  static const danger = Color(0xFFFF7089);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF9D80FF), Color(0xFF5533E4)],
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
        brightness: Brightness.dark,
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
      brightness: Brightness.dark,
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
      backgroundColor: AppColors.surfaceRaised,
      contentTextStyle: const TextStyle(
        color: AppColors.textPrimary,
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
