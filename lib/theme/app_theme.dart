import 'package:flutter/material.dart';

/// WinForms와 동일한 색상 (bgDark, bgPanel, fg, accent, LogRed)
class AppTheme {
  // 메인 톤: 다크 배경 1톤 + 포인트 컬러 1톤 (토스 느낌의 심플한 구성)
  static const Color bgDark = Color(0xFF050816); // 거의 검은 남색 계열
  static const Color bgPanel = Color(0xFF0C1220); // 살짝 떠 보이는 카드 배경
  static const Color bgInput = Color(0xFF111827);
  static const Color fg = Color(0xFFE5E7EB); // 밝은 그레이
  static const Color accent = Color(0xFF4EC9B0); // 기존 포인트 유지 (민트)
  static const Color logRed = Color(0xFFFF6464);
  static const Color muted = Color(0xFF6B7280);
  static const Color buttonStopBg = Color(0xFF1F2933);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      colorScheme: const ColorScheme.dark(
        surface: bgPanel,
        primary: accent,
        secondary: accent,
        onPrimary: bgDark,
        error: logRed,
        onSurface: fg,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: fg,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
      cardTheme:
      CardThemeData(

        color: bgPanel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: bgDark,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: muted,
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgInput,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: bgInput),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: accent),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: muted),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: fg, fontSize: 14),
        bodyMedium: TextStyle(color: fg, fontSize: 14),
        titleMedium: TextStyle(color: fg, fontWeight: FontWeight.w500),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bgPanel,
        selectedItemColor: accent,
        unselectedItemColor: muted,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}
