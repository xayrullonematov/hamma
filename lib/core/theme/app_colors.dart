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

  // Subtle 10%-white overlay used by Material highlight/hover states
  // when we want a brutalist "just barely visible" press feedback. Kept
  // here so we don't sprinkle Colors.white10 literals across the app.
  static const overlayHover = Color(0x1AFFFFFF);

  // Brand cyan — extracted from the Hamma logo (H mark).
  // 11:1 contrast on pure black — WCAG AAA.
  static const accent = Color(0xFF4ECDC4);

  // Per-category brutalist accents used by the settings row tiles so each
  // category card has a visually distinct icon swatch while keeping the
  // overall monochrome surface.
  static const accentAi = Color(0xFF4ECDC4);
  static const accentTriage = Color(0xFFE0B33C);
  static const accentHealth = Color(0xFF6BCB77);
  static const accentSecurity = Color(0xFFFF5C5C);
  static const accentBackup = Color(0xFF4D96FF);
  static const accentSupport = Color(0xFFB084EB);
  // Dimmer variant for subtle accent surfaces (borders, inactive tints).
  static const accentDim = Color(0xFF1A4A47);

  // Logo asset path.
  static const logoAsset = 'assets/images/logo.png';

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
