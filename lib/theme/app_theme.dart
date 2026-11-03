/// The design system, taken from the design canvas rather than invented.
///
/// Every value here appears in the canvas. Where a screen needs something the
/// canvas does not define, it is derived from these rather than picked fresh,
/// so the app stays one coherent thing.
library;

import 'package:flutter/material.dart';

/// Colours, named for what they mean rather than what they look like.
abstract final class AppColors {
  /// Deep green. Nav rail, headers, selected state, chart bars.
  static const Color primary = Color(0xFF0F4A33);

  /// Body text.
  static const Color ink = Color(0xFF14231B);

  /// Amber. The ONE primary action on a screen: Charge, Save, Start billing.
  /// Using it twice on one screen means the screen has two primary actions,
  /// which it should not.
  static const Color accent = Color(0xFFF4B400);

  /// Cards and panels.
  static const Color surface = Color(0xFFFFFFFF);

  /// The app background behind the cards.
  static const Color background = Color(0xFFF4F6F1);

  /// Secondary labels and help text. 4.5:1 on white and on [background].
  static const Color muted = Color(0xFF47564D);

  /// Input outlines.
  static const Color border = Color(0xFFA9B5AD);

  /// Card outlines and dividers, lighter than [border].
  static const Color borderSoft = Color(0xFFD5DBD6);

  /// Selected chips, "Connected" badges, anything affirmative.
  static const Color softGreen = Color(0xFFDDEBE2);

  /// Neutral fills: segmented control tracks, progress backgrounds.
  static const Color neutral = Color(0xFFE3E8E2);
  static const Color neutralAlt = Color(0xFFE9EDE8);

  /// Destructive actions: cancel a bill, delete.
  static const Color danger = Color(0xFFA3241C);
  static const Color dangerBg = Color(0xFFFBE6E4);
  static const Color dangerText = Color(0xFF7E1B14);

  /// Warnings: turnover approaching a threshold, stale backup.
  static const Color warnBg = Color(0xFFFDF0C9);
  static const Color warnText = Color(0xFF5C4300);

  /// Scrim behind a modal dialog.
  static const Color scrim = Color(0x9E092016);
}

/// Corner radii. The canvas uses three.
abstract final class AppRadius {
  /// Small controls: inputs, keypad keys on tablet, small buttons.
  static const double small = 10;

  /// The default. Cards, buttons, chips.
  static const double medium = 12;

  /// Large buttons, dialogs, the PIN keypad.
  static const double large = 14;

  /// The sheet that slides up over the login background on a phone.
  static const double sheet = 24;

  /// Fully round: pills and filter chips.
  static const double pill = 22;
}

/// Spacing, on a 4px grid.
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// Minimum touch targets.
///
/// These are not suggestions. This app is used at speed, one-handed, by someone
/// whose other hand is holding a plate, and often with wet or oily fingers.
abstract final class AppTouch {
  /// The floor for anything tappable. Matches the canvas and exceeds the
  /// Material minimum of 48.
  static const double min = 44;

  /// Ordinary buttons and list rows.
  static const double comfortable = 52;

  /// Keypad keys and item tiles.
  static const double large = 68;

  /// The single primary action, and the user picker on the login screen.
  static const double primary = 76;
}

/// Where the layout switches from phone to tablet.
///
/// The canvas has two designs: 390 wide for a phone and 1280 for a tablet. The
/// tablet one puts the bill beside the item grid; the phone one stacks steps.
/// 600 is the conventional Material breakpoint and sits comfortably between.
const double kTabletBreakpoint = 600;

/// True when this screen should use the two-pane tablet layout.
bool isTablet(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kTabletBreakpoint;

/// The bundled font family. Declared in pubspec.yaml, never fetched.
const String kFontFamily = 'AnekTelugu';

/// The app's theme.
ThemeData buildAppTheme() {
  const colorScheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    onSecondary: AppColors.ink,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    error: AppColors.danger,
    onError: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    fontFamily: kFontFamily,
    scaffoldBackgroundColor: AppColors.background,

    // The canvas has no shadows anywhere: it separates surfaces with colour and
    // a hairline border instead. Shadows on a screen used in bright daylight
    // mostly add mud.
    cardTheme: const CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),

    textTheme: const TextTheme(
      // 52px: the restaurant name on the tablet login.
      displayLarge: TextStyle(
        fontSize: 52,
        fontWeight: FontWeight.w700,
        height: 1.1,
        color: AppColors.ink,
      ),
      // 36px: "Bill saved and printed".
      displayMedium: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        height: 1.15,
        color: AppColors.ink,
      ),
      // 32px: the restaurant name on a phone.
      displaySmall: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.1,
        color: AppColors.ink,
      ),
      // 28px: screen titles.
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      // 22px: panel headings, totals.
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      // 20px: section headings.
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      // 18px: emphasised body, prompts.
      titleMedium: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      // 17px: body.
      bodyLarge: TextStyle(fontSize: 17, color: AppColors.ink),
      // 15px: the workhorse. Most labels in the canvas are this size.
      bodyMedium: TextStyle(fontSize: 15, color: AppColors.ink),
      // 14px: the smallest text used, for captions only.
      bodySmall: TextStyle(fontSize: 14, color: AppColors.muted),
      // 16px semibold: button text.
      labelLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.lg,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      labelStyle: const TextStyle(fontSize: 15, color: AppColors.muted),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, AppTouch.comfortable),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          fontFamily: kFontFamily,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        minimumSize: const Size(0, AppTouch.comfortable),
        side: const BorderSide(color: AppColors.primary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          fontFamily: kFontFamily,
        ),
      ),
    ),

    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.ink,
      contentTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontFamily: kFontFamily,
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// The amber primary-action button. One per screen, never two.
///
/// Not a theme on [FilledButton] because amber is deliberately awkward to
/// reach for: having to name it makes using it twice a visible decision.
ButtonStyle primaryActionStyle({double height = AppTouch.large}) =>
    FilledButton.styleFrom(
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.ink,
      disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.45),
      disabledForegroundColor: AppColors.ink.withValues(alpha: 0.6),
      minimumSize: Size(0, height),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      textStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        fontFamily: kFontFamily,
      ),
    );
