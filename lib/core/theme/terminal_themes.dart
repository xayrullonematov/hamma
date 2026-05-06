import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

class AppTerminalThemes {
  AppTerminalThemes._();

  static TerminalTheme get(String name) {
    switch (name.toLowerCase()) {
      case 'solarized':
        return solarized;
      case 'matrix':
        return matrix;
      case 'ocean':
        return ocean;
      case 'brutalist':
      default:
        return brutalist;
    }
  }

  static const brutalist = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0x44FFFFFF),
    foreground: Color(0xFFFFFFFF),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFFF0000),
    green: Color(0xFF00FF00),
    yellow: Color(0xFFFFFF00),
    blue: Color(0xFF0000FF),
    magenta: Color(0xFFFF00FF),
    cyan: Color(0xFF00FFFF),
    white: Color(0xFFFFFFFF),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFFF0000),
    brightGreen: Color(0xFF00FF00),
    brightYellow: Color(0xFFFFFF00),
    brightBlue: Color(0xFF0000FF),
    brightMagenta: Color(0xFFFF00FF),
    brightCyan: Color(0xFF00FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF00),
    searchHitBackgroundCurrent: Color(0xFF00FF00),
    searchHitForeground: Color(0xFF000000),
  );

  static const solarized = TerminalTheme(
    cursor: Color(0xFF93A1A1),
    selection: Color(0x4493A1A1),
    foreground: Color(0xFF839496),
    background: Color(0xFF002B36),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0xFFFFFF00),
    searchHitBackgroundCurrent: Color(0xFF00FF00),
    searchHitForeground: Color(0xFF000000),
  );

  static const matrix = TerminalTheme(
    cursor: Color(0xFF00FF41),
    selection: Color(0x4400FF41),
    foreground: Color(0xFF00FF41),
    background: Color(0xFF0D0208),
    black: Color(0xFF000000),
    red: Color(0xFFFF0000),
    green: Color(0xFF00FF41),
    yellow: Color(0xFFFFFF00),
    blue: Color(0xFF0000FF),
    magenta: Color(0xFFFF00FF),
    cyan: Color(0xFF00FFFF),
    white: Color(0xFFFFFFFF),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFFF0000),
    brightGreen: Color(0xFF00FF41),
    brightYellow: Color(0xFFFFFF00),
    brightBlue: Color(0xFF0000FF),
    brightMagenta: Color(0xFFFF00FF),
    brightCyan: Color(0xFF00FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF00FF41),
    searchHitBackgroundCurrent: Color(0xFF00FF41),
    searchHitForeground: Color(0xFF000000),
  );

  static const ocean = TerminalTheme(
    cursor: Color(0xFF4ECDC4),
    selection: Color(0x444ECDC4),
    foreground: Color(0xFFE0FBFC),
    background: Color(0xFF0B132B),
    black: Color(0xFF1C2541),
    red: Color(0xFFFF5C5C),
    green: Color(0xFF6BCB77),
    yellow: Color(0xFFE0B33C),
    blue: Color(0xFF4D96FF),
    magenta: Color(0xFFB084EB),
    cyan: Color(0xFF4ECDC4),
    white: Color(0xFFFFFFFF),
    brightBlack: Color(0xFF3A506B),
    brightRed: Color(0xFFFF5C5C),
    brightGreen: Color(0xFF6BCB77),
    brightYellow: Color(0xFFE0B33C),
    brightBlue: Color(0xFF4D96FF),
    brightMagenta: Color(0xFFB084EB),
    brightCyan: Color(0xFF4ECDC4),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF4ECDC4),
    searchHitBackgroundCurrent: Color(0xFF4ECDC4),
    searchHitForeground: Color(0xFF000000),
  );
}
