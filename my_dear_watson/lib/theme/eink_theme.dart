import 'package:flutter/material.dart';

/// Elegant, high-contrast theme for e-ink — pen on fine paper.
final einkTheme = ThemeData(
  brightness: Brightness.light,
  colorScheme: const ColorScheme.light(
    primary: Color(0xFF1A1A1A),
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: Color(0xFF1A1A1A),
  ),
  scaffoldBackgroundColor: Colors.white,
  fontFamily: 'serif',
  textTheme: const TextTheme(
    bodyLarge: TextStyle(
      fontSize: 18,
      color: Color(0xFF1A1A1A),
      height: 1.6,
      letterSpacing: 0.2,
    ),
    bodyMedium: TextStyle(
      fontSize: 16,
      color: Color(0xFF1A1A1A),
      height: 1.5,
      letterSpacing: 0.15,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w400,
      color: Color(0xFF1A1A1A),
      letterSpacing: 1.5,
    ),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: Color(0xFF1A1A1A),
    elevation: 0,
    titleTextStyle: TextStyle(
      fontFamily: 'serif',
      fontSize: 20,
      fontWeight: FontWeight.w400,
      color: Color(0xFF1A1A1A),
      letterSpacing: 2.0,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    border: OutlineInputBorder(
      borderSide: const BorderSide(color: Color(0xFF1A1A1A), width: 1),
      borderRadius: BorderRadius.circular(2),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Color(0xFF1A1A1A), width: 1.5),
      borderRadius: BorderRadius.circular(2),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    labelStyle: const TextStyle(
      fontFamily: 'serif',
      fontSize: 16,
      letterSpacing: 0.5,
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF1A1A1A),
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      textStyle: const TextStyle(
        fontFamily: 'serif',
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 1.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      elevation: 0,
    ),
  ),
  dividerTheme: const DividerThemeData(
    color: Color(0xFF1A1A1A),
    thickness: 0.5,
  ),
  splashFactory: NoSplash.splashFactory,
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
    },
  ),
);
