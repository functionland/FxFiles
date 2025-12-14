import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary brand colors (matching Fx component library - teal/cyan focus)
  static const Color primary = Color(0xFF00D4AA);       // Fx teal/cyan primary
  static const Color primaryHover = Color(0xFF00B894);
  static const Color primaryPressed = Color(0xFF009B7D);
  static const Color primaryLight = Color(0xFF4AE3C4);  // Lighter variant
  static const Color secondary = Color(0xFF6366F1);     // Indigo secondary
  static const Color accent = Color(0xFF06B6D4);        // Cyan accent

  // Status colors (matching Fx component library)
  static const Color success = Color(0xFF22C55E);
  static const Color successBase = Color(0xFF10B981);
  static const Color successLight = Color(0xFFDCFCE7);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningBase = Color(0xFFF59E0B);
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color warning50 = Color(0xFFFFFBEB);
  static const Color warning200 = Color(0xFFFDE68A);
  static const Color warning700 = Color(0xFFB45309);
  static const Color warning800 = Color(0xFF92400E);
  static const Color error = Color(0xFFEF4444);
  static const Color errorBase = Color(0xFFEF4444);
  static const Color errorLight = Color(0xFFFEE2E2);

  // Green tones for usage/pool indicators (Fx style)
  static const Color greenBase = Color(0xFF00D4AA);     // Match Fx teal
  static const Color greenHover = Color(0xFF00B894);
  static const Color greenPressed = Color(0xFF009B7D);
  static const Color poolUsed = Color(0xFF00D4AA);
  static const Color poolFree = Color(0xFF1E293B);

  // Content/Text colors (light theme)
  static const Color content1Light = Color(0xFF1F2937);  // Primary text
  static const Color content2Light = Color(0xFF6B7280);  // Secondary text
  static const Color content3Light = Color(0xFF9CA3AF);  // Tertiary text

  // Content/Text colors (dark theme) - Fx dark mode
  static const Color content1Dark = Color(0xFFFFFFFF);   // Primary text - pure white
  static const Color content2Dark = Color(0xFFA1A1AA);   // Secondary text - zinc-400
  static const Color content3Dark = Color(0xFF71717A);   // Tertiary text - zinc-500

  // Legacy text colors
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);

  // Background colors (light theme)
  static const Color backgroundPrimaryLight = Color(0xFFF8FAFC);   // slate-50
  static const Color backgroundSecondaryLight = Color(0xFFFFFFFF);
  
  // Background colors (dark theme) - matching Fx dark theme exactly
  static const Color backgroundPrimaryDark = Color(0xFF0A0A0A);    // Near black (Fx main bg)
  static const Color backgroundSecondaryDark = Color(0xFF171717);  // Slightly lighter (neutral-900)
  static const Color backgroundTertiaryDark = Color(0xFF262626);   // Card background (neutral-800)

  // Legacy background colors
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color backgroundDark = Color(0xFF0A0A0A);
  static const Color surfaceLight = Colors.white;
  static const Color surfaceDark = Color(0xFF171717);

  // Border colors
  static const Color borderLight = Color(0xFFE2E8F0);   // slate-200
  static const Color borderDark = Color(0xFF262626);    // neutral-800
  static const Color divider = Color(0xFFE2E8F0);
  static const Color border = Color(0xFFCBD5E1);        // slate-300

  // Card colors
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF171717);      // neutral-900
  
  // Bottom sheet / Modal colors
  static const Color bottomSheetLight = Color(0xFFFFFFFF);
  static const Color bottomSheetDark = Color(0xFF1C1C1E);  // iOS-style dark sheet
  
  // Icon colors
  static const Color iconLight = Color(0xFF64748B);     // slate-500
  static const Color iconDark = Color(0xFFA1A1AA);      // zinc-400
}
