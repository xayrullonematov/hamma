import 'package:flutter/material.dart';

/// Brutalist monochrome palette — Terafab visual identity.
///
/// Pure black scaffold, near-black surfaces, white primary, harsh red for
/// risk/danger. No soft slate/blue/gray accents anywhere in the app.
class AppColors {
  AppColors._();

  // Core surfaces
  static const scaffoldBackground = Color(0xFF000000);
  static const surface = Color(0xFF0A0A0A);
  static const panel = Color(0xFF050505);

  // Borders (wireframe — replace shadows)
  static const border = Color(0xFF222222);
  static const borderStrong = Colors.white24;

  // Foreground
  static const textPrimary = Color(0xFFFFFFFF);
  // 5.7:1 contrast on black — passes WCAG AA for normal text.
  static const textMuted = Color(0xFF888888);
  // 4.6:1 contrast on black — passes WCAG AA for normal text.
  // (Was 0xFF555555 / 2.8:1 — failed AA, replaced for accessibility.)
  static const textFaint = Color(0xFF767676);

  // Accents
  static const primary = Color(0xFFFFFFFF);
  static const onPrimary = Color(0xFF000000);
  static const danger = Color(0xFFFF0000);
  static const success = Color(0xFFFFFFFF);
  static const warning = Color(0xFFFF0000);

  // Terminal
  static const terminalBlack = Color(0xFF000000);
  static const terminalGreen = Color(0xFFFFFFFF);

  // Typography
  static const sansFamily = 'Inter';
  static const monoFamily = 'JetBrains Mono';
  static const List<String> sansFallback = <String>[
    'Geist',
    'Space Grotesk',
    'SF Pro Display',
    'Segoe UI',
    'Roboto',
    'sans-serif',
  ];
  static const List<String> monoFallback = <String>[
    'Geist Mono',
    'IBM Plex Mono',
    'Fira Code',
    'Menlo',
    'Consolas',
    'monospace',
  ];
}
