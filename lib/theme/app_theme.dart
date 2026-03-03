import 'package:flutter/material.dart';

/// WinForms와 동일한 색상 (bgDark, bgPanel, fg, accent, LogRed)
class AppTheme {
  static const Color bgDark = Color(0xFF1E1E1E);
  static const Color bgPanel = Color(0xFF2D2D30);
  static const Color bgInput = Color(0xFF252526);
  static const Color fg = Color(0xFFD4D4D4);
  static const Color accent = Color(0xFF4EC9B0); // 78, 201, 176
  static const Color logRed = Color(0xFFFF6464);
  static const Color muted = Color(0xFF969696);
  static const Color buttonStopBg = Color(0xFF505050);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      colorScheme: ColorScheme.dark(
        surface: bgDark,
        primary: accent,
        onPrimary: bgDark,
        error: logRed,
        onSurface: fg,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgPanel,
        foregroundColor: fg,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: bgDark,
          elevation: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgInput,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: const TextStyle(color: muted),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: fg, fontSize: 14),
        bodyMedium: TextStyle(color: fg, fontSize: 14),
        titleMedium: TextStyle(color: fg, fontWeight: FontWeight.w500),
      ),
    );
  }
}
