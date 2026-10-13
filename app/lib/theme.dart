/// App theme and design system for Vetifi.
///
/// Professional, clean design suitable for medical/veterinary use.
/// High contrast, clear typography, and unmistakable result display.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class VetifiTheme {
  // Brand colours — Modern Medical Sapphire, Cobalt & Azure
  static const Color primary = Color(0xFF1E40AF); // Rich royal sapphire blue
  static const Color primaryLight = Color(0xFF3B82F6); // Vibrant cobalt blue
  static const Color primaryDark = Color(0xFF0F2B5C); // Deep midnight navy
  static const Color secondary = Color(0xFF0284C7); // Electric azure/cyan
  static const Color surface = Color(0xFFF8FAFC);
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF1F5F9); // Clean cool slate

  // Smooth horizontal gradient across top headers (Navy to Cobalt)
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0xFF1E3A8A), // Deep navy sapphire
      Color(0xFF2563EB), // Rich cobalt blue
    ],
  );

  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
  );

  // Semantic colours
  static const Color error = Color(0xFFDC2626);
  static const Color errorBg = Color(0xFFFEF2F2);
  static const Color warning = Color(0xFFD97706);
  static const Color warningBg = Color(0xFFFFFBEB);
  static const Color success = Color(0xFF059669);
  static const Color successBg = Color(0xFFF0FDF4);
  static const Color info = Color(0xFF2563EB);
  static const Color infoBg = Color(0xFFEFF6FF);

  // Text colours
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textMuted = Color(0xFF94A3B8);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Result display — dark high-contrast card with electric cyan/azure readout
  static const Color resultBg = Color(0xFF0B132B); // Cosmic midnight blue
  static const Color resultText = Color(0xFFFFFFFF);
  static const Color resultAccent = Color(
    0xFF38BDF8,
  ); // Radiant sky/cyan blue for volume
  static const Color cappedWarning = Color(0xFFFBBF24); // Yellow for capped

  // Withdrawn drug
  static const Color withdrawnBg = Color(0xFFFEE2E2);
  static const Color withdrawnBorder = Color(0xFFEF4444);

  static ThemeData get theme => themeFor(null);

  static ThemeData themeFor(dynamic lang) {
    final isKannada = lang != null && lang.toString().contains('kn');
    final textTheme = isKannada
        ? GoogleFonts.notoSansKannadaTextTheme()
        : GoogleFonts.plusJakartaSansTextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        secondary: secondary,
        error: error,
        surface: surface,
      ),
      scaffoldBackgroundColor: background,
      textTheme: textTheme.copyWith(
        headlineLarge: textTheme.headlineLarge?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 28,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 22,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 18,
        ),
        titleMedium: textTheme.titleMedium?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          color: textPrimary,
          fontSize: 16,
        ),
        bodyMedium: textTheme.bodyMedium?.copyWith(
          color: textSecondary,
          fontSize: 14,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(
          color: textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: primary,
        foregroundColor: textOnPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textOnPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        elevation: 1.5,
        shadowColor: const Color(0xFF0F172A).withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceCard,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: textOnPrimary,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: primary.withValues(alpha: 0.15),
        labelStyle: GoogleFonts.plusJakartaSans(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: Colors.grey.shade300),
      ),
    );
  }
}
