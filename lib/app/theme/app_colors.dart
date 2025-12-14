import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Primary brand colors (matching Fx component library)
  static const Color primary = Color(0xFF06B597);       // Fx primary green
  static const Color primaryHover = Color(0xFF06B597);  // Hover state
  static const Color primaryPressed = Color(0xFF038082); // Pressed state
  static const Color primaryLight = Color(0xFF049B8F);  // Base variant
  static const Color secondary = Color(0xFF099393);     // Viridian green secondary
  static const Color accent = Color(0xFF187AF9);        // Blue crayola accent

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
  static const Color greenBase = Color(0xFF049B8F);     // Match Fx green base
  static const Color greenHover = Color(0xFF06B597);    // Hover variant
  static const Color greenPressed = Color(0xFF038082);  // Pressed variant
  static const Color poolUsed = Color(0xFF00D4AA);
  static const Color poolFree = Color(0xFF1E293B);

  // Content/Text colors (light theme)
  static const Color content1Light = Color(0xFF1F2937);  // Primary text
  static const Color content2Light = Color(0xFF6B7280);  // Secondary text
  static const Color content3Light = Color(0xFF9CA3AF);  // Tertiary text

  // Content/Text colors (dark theme) - Fx dark mode
  static const Color content1Dark = Color(0xFFF8F9FA);   // Primary text (gray-dark-content1)
  static const Color content2Dark = Color(0xFFE9ECEF);   // Secondary text (gray-dark-content2)
  static const Color content3Dark = Color(0xFFCED4DA);   // Tertiary text (gray-dark-content3)

  // Legacy text colors
  static const Color textPrimary = Color(0xFF1F2937);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);

  // Background colors (light theme)
  static const Color backgroundPrimaryLight = Color(0xFFF8FAFC);   // slate-50
  static const Color backgroundSecondaryLight = Color(0xFFFFFFFF);
  
  // Background colors (dark theme) - matching Fx dark theme exactly
  static const Color backgroundPrimaryDark = Color(0xFF212529);    // Main dark (main-dark)
  static const Color backgroundSecondaryDark = Color(0xFF343A40);  // App bg (gray-dark-app-bg)
  static const Color backgroundTertiaryDark = Color(0xFF495057);   // Secondary bg (gray-dark-bg-secondary)

  // Legacy background colors
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color backgroundDark = Color(0xFF0A0A0A);
  static const Color surfaceLight = Colors.white;
  static const Color surfaceDark = Color(0xFF171717);

  // Border colors
  static const Color borderLight = Color(0xFFCED4DA);   // gray-light-border
  static const Color borderDark = Color(0xFF868E96);    // gray-dark-border
  static const Color divider = Color(0xFFE2E8F0);
  static const Color border = Color(0xFFCBD5E1);        // slate-300

  // Card colors
  static const Color cardLight = Color(0xFFF8F9FA);     // gray-light-bg-primary
  static const Color cardDark = Color(0xFF343A40);      // gray-dark-bg-primary
  
  // Bottom sheet / Modal colors
  static const Color bottomSheetLight = Color(0xFFFFFFFF);
  static const Color bottomSheetDark = Color(0xFF1C1C1E);  // iOS-style dark sheet
  
  // Icon colors
  static const Color iconLight = Color(0xFF64748B);     // slate-500
  static const Color iconDark = Color(0xFFA1A1AA);      // zinc-400
}
