import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary brand colors (matching Fx component library)
  static const Color primary = Color(0xFF6366F1);      // Indigo/purple primary
  static const Color primaryHover = Color(0xFF4F46E5);
  static const Color primaryPressed = Color(0xFF4338CA);
  static const Color secondary = Color(0xFF8B5CF6);
  static const Color accent = Color(0xFF06B6D4);

  // Status colors
  static const Color success = Color(0xFF22C55E);
  static const Color successBase = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningBase = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color errorBase = Color(0xFFEF4444);

  // Green tones for usage/pool indicators
  static const Color greenBase = Color(0xFF22C55E);
  static const Color greenHover = Color(0xFF16A34A);
  static const Color greenPressed = Color(0xFF15803D);

  // Content/Text colors (light theme)
  static const Color content1Light = Color(0xFF1F2937);  // Primary text
  static const Color content2Light = Color(0xFF6B7280);  // Secondary text
  static const Color content3Light = Color(0xFF9CA3AF);  // Tertiary text

  // Content/Text colors (dark theme)
  static const Color content1Dark = Color(0xFFF9FAFB);   // Primary text
  static const Color content2Dark = Color(0xFF9CA3AF);   // Secondary text
  static const Color content3Dark = Color(0xFF6B7280);   // Tertiary text

  // Legacy text colors
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);

  // Background colors (light theme)
  static const Color backgroundPrimaryLight = Color(0xFFF9FAFB);
  static const Color backgroundSecondaryLight = Color(0xFFFFFFFF);
  
  // Background colors (dark theme) - matching Fx dark theme
  static const Color backgroundPrimaryDark = Color(0xFF0F172A);    // Deep dark blue
  static const Color backgroundSecondaryDark = Color(0xFF1E293B);  // Slightly lighter

  // Legacy background colors
  static const Color backgroundLight = Color(0xFFF9FAFB);
  static const Color backgroundDark = Color(0xFF0F172A);
  static const Color surfaceLight = Colors.white;
  static const Color surfaceDark = Color(0xFF1E293B);

  // Border colors
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color borderDark = Color(0xFF334155);
  static const Color divider = Color(0xFFE5E7EB);
  static const Color border = Color(0xFFD1D5DB);

  // Card colors
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF1E293B);
}
