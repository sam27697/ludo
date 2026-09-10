import 'package:flutter/material.dart';

/// Brand colours for Ludo RNG. Felt-table teal and cool mint paper — not the
/// Material 3 default purple, not cream-and-terracotta, not a dark theme.
abstract final class LudoColors {
  static const Color feltDeep = Color(0xFF0A3D38);
  static const Color feltMid = Color(0xFF14665C);
  static const Color feltLight = Color(0xFF2A8F82);

  /// Cool mint paper. Deliberately off the warm-cream #F4F1EA cliché.
  static const Color paper = Color(0xFFEEF6F3);
  static const Color paperElevated = Color(0xFFF7FBFA);

  static const Color ink = Color(0xFF0A2A27);
  static const Color inkMuted = Color(0xFF3D5F5A);

  static const Color dieFace = Color(0xFFFAF7F0);
  static const Color dieEdge = Color(0xFF0A2A27);

  static const Color action = Color(0xFF0F6B5F);
  static const Color actionOn = Color(0xFFF7FBFA);

  /// Seat colours — same as [board.dart], kept here for the brand die.
  static const List<Color> seats = <Color>[
    Color(0xFFD32F2F),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
    Color(0xFF1976D2),
  ];
}

/// Latin UI face. Arabic falls back to Noto Sans Arabic via [fontFamilyFallback].
const String kLudoFontFamily = 'Poppins';
const List<String> kLudoFontFallbacks = <String>['Noto Sans Arabic'];

TextTheme _ludoTextTheme(TextTheme base) {
  TextStyle face(TextStyle? s) => (s ?? const TextStyle()).copyWith(
    fontFamily: kLudoFontFamily,
    fontFamilyFallback: kLudoFontFallbacks,
  );

  return base.copyWith(
    displayLarge: face(base.displayLarge),
    displayMedium: face(base.displayMedium),
    displaySmall: face(base.displaySmall),
    headlineLarge: face(base.headlineLarge)
        .copyWith(fontWeight: FontWeight.w700),
    headlineMedium: face(base.headlineMedium)
        .copyWith(fontWeight: FontWeight.w700),
    headlineSmall: face(base.headlineSmall)
        .copyWith(fontWeight: FontWeight.w600),
    titleLarge: face(base.titleLarge).copyWith(fontWeight: FontWeight.w600),
    titleMedium: face(base.titleMedium),
    titleSmall: face(base.titleSmall),
    bodyLarge: face(base.bodyLarge),
    bodyMedium: face(base.bodyMedium),
    bodySmall: face(base.bodySmall),
    labelLarge: face(base.labelLarge).copyWith(fontWeight: FontWeight.w600),
    labelMedium: face(base.labelMedium),
    labelSmall: face(base.labelSmall),
  );
}

/// Shared Material theme. Seeded on felt teal so every screen inherits the
/// same product colour, not Material's default purple seed.
ThemeData buildAppTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: LudoColors.action,
    brightness: Brightness.light,
    primary: LudoColors.action,
    onPrimary: LudoColors.actionOn,
    secondary: LudoColors.feltMid,
    onSecondary: LudoColors.actionOn,
    surface: LudoColors.paperElevated,
    onSurface: LudoColors.ink,
    error: const Color(0xFFB3261E),
  );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: LudoColors.paper,
    fontFamily: kLudoFontFamily,
    fontFamilyFallback: kLudoFontFallbacks,
  );

  return base.copyWith(
    textTheme: _ludoTextTheme(base.textTheme),
    primaryTextTheme: _ludoTextTheme(base.primaryTextTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: LudoColors.paperElevated,
      foregroundColor: LudoColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: kLudoFontFamily,
        fontFamilyFallback: kLudoFontFallbacks,
        fontWeight: FontWeight.w600,
        fontSize: 18,
        color: LudoColors.ink,
      ),
    ),
    // AppBar only threads foreground into IconTheme / IconButtonTheme, never
    // TextButtonTheme — so a locale toggle TextButton must be set here once.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LudoColors.action,
        foregroundColor: LudoColors.actionOn,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: kLudoFontFamily,
          fontFamilyFallback: kLudoFontFallbacks,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LudoColors.ink,
        side: const BorderSide(color: LudoColors.feltMid, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LudoColors.paperElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: LudoColors.feltLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: LudoColors.feltLight.withValues(alpha: 0.7),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: LudoColors.action, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error),
      ),
      labelStyle: const TextStyle(color: LudoColors.inkMuted),
      hintStyle: TextStyle(color: LudoColors.inkMuted.withValues(alpha: 0.7)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.comfortable,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LudoColors.actionOn;
          }
          return LudoColors.ink;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LudoColors.action;
          }
          return LudoColors.paperElevated;
        }),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: LudoColors.action,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: LudoColors.feltDeep,
      contentTextStyle: const TextStyle(
        fontFamily: kLudoFontFamily,
        fontFamilyFallback: kLudoFontFallbacks,
        color: LudoColors.actionOn,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// Full-bleed felt atmosphere used behind the home composition. A soft
/// vertical wash plus a faint grid so the screen does not read as a flat
/// fill, without competing with the die mark.
class FeltBackdrop extends StatelessWidget {
  const FeltBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xFFD8EEE8),
            LudoColors.paper,
            Color(0xFFD2E8E2),
          ],
          stops: <double>[0.0, 0.45, 1.0],
        ),
      ),
      child: CustomPaint(painter: const _FeltGrainPainter(), child: child),
    );
  }
}

class _FeltGrainPainter extends CustomPainter {
  const _FeltGrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = LudoColors.feltMid.withValues(alpha: 0.045)
      ..strokeWidth = 1;

    const double step = 28;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }

    final Paint wash = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.35),
        radius: 1.05,
        colors: <Color>[
          LudoColors.feltLight.withValues(alpha: 0.18),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wash);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
