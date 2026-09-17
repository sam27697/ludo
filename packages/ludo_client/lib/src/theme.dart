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

  /// Status / feedback. Material error red, named once for the paintbox.
  static const Color error = Color(0xFFB3261E);

  /// Soft mint washes behind the home felt composition (not flat paper).
  static const Color paperWashTop = Color(0xFFD8EEE8);
  static const Color paperWashBottom = Color(0xFFD2E8E2);

  /// Seat colours: single source for board yards/tokens and the brand die.
  static const List<Color> seats = <Color>[
    Color(0xFFD32F2F),
    Color(0xFF388E3C),
    Color(0xFFFBC02D),
    Color(0xFF1976D2),
  ];
}

/// Dark-mode brand colours. Sample ink/paper and action/paper pairs meet
/// WCAG AA (at least 4.5:1). Wired for stubs and future dark ThemeData.
abstract final class LudoColorsDark {
  static const Color paper = Color(0xFF0A1F1C);
  static const Color paperElevated = Color(0xFF12302B);
  static const Color ink = Color(0xFFEEF6F3);
  static const Color inkMuted = Color(0xFF9BB5B0);
  static const Color action = Color(0xFF5CDBB8);
  static const Color actionOn = Color(0xFF0A1F1C);
  static const Color felt = Color(0xFF14665C);
}

/// Neon underfelt arcade-night spike palette (Wild direction). Deep-void
/// paper with cyan action fringe; ink/paper and action/paper pairs meet
/// WCAG AA (at least 4.5:1). Used only by [buildNeonUnderfeltTheme].
abstract final class LudoColorsNeon {
  static const Color feltDeep = Color(0xFF061820);
  static const Color feltMid = Color(0xFF0A3D4A);
  static const Color feltLight = Color(0xFF1A6B7A);

  /// Deep void paper - deliberately not Bold mint [LudoColors.paper].
  static const Color paper = Color(0xFF070B14);
  static const Color paperElevated = Color(0xFF0F1624);

  static const Color ink = Color(0xFFE8F4FF);
  static const Color inkMuted = Color(0xFF9BB4C8);

  static const Color action = Color(0xFF00D4E8);
  static const Color actionOn = Color(0xFF070B14);

  static const Color error = Color(0xFFFF4D6A);

  static const Color paperWashTop = Color(0xFF0A1220);
  static const Color paperWashBottom = Color(0xFF050810);

  /// Electric seat glows for the arcade-night direction.
  static const List<Color> seats = <Color>[
    Color(0xFFFF3D71),
    Color(0xFF39FF14),
    Color(0xFFFFE600),
    Color(0xFF00B7FF),
  ];
}

/// Latin UI face. Arabic falls back to Noto Sans Arabic via [fontFamilyFallback].
const String kLudoFontFamily = 'Poppins';
const List<String> kLudoFontFallbacks = <String>['Noto Sans Arabic'];

/// Named type-token sizes. Screens and themes reference these, not literals.
const double kTypeTitle = 18;
const double kTypeLabel = 16;

/// Motion duration tokens: short UI at most 300ms, long transitions at most 500ms.
const Duration kMotionShort = Duration(milliseconds: 200);
const Duration kMotionLong = Duration(milliseconds: 400);

/// Single control radius role used across buttons, inputs, chips, snackbars.
const double kRadiusControl = 12;

/// Brand colours and motion readable from [Theme.of] via ThemeExtension.
@immutable
class LudoBrand extends ThemeExtension<LudoBrand> {
  const LudoBrand({
    required this.action,
    required this.ink,
    required this.paper,
    required this.felt,
    required this.motionShort,
    required this.motionLong,
  });

  final Color action;
  final Color ink;
  final Color paper;
  final Color felt;
  final Duration motionShort;
  final Duration motionLong;

  static const LudoBrand light = LudoBrand(
    action: LudoColors.action,
    ink: LudoColors.ink,
    paper: LudoColors.paper,
    felt: LudoColors.feltDeep,
    motionShort: kMotionShort,
    motionLong: kMotionLong,
  );

  static const LudoBrand dark = LudoBrand(
    action: LudoColorsDark.action,
    ink: LudoColorsDark.ink,
    paper: LudoColorsDark.paper,
    felt: LudoColorsDark.felt,
    motionShort: kMotionShort,
    motionLong: kMotionLong,
  );

  static const LudoBrand neon = LudoBrand(
    action: LudoColorsNeon.action,
    ink: LudoColorsNeon.ink,
    paper: LudoColorsNeon.paper,
    felt: LudoColorsNeon.feltDeep,
    motionShort: kMotionShort,
    motionLong: kMotionLong,
  );

  @override
  LudoBrand copyWith({
    Color? action,
    Color? ink,
    Color? paper,
    Color? felt,
    Duration? motionShort,
    Duration? motionLong,
  }) {
    return LudoBrand(
      action: action ?? this.action,
      ink: ink ?? this.ink,
      paper: paper ?? this.paper,
      felt: felt ?? this.felt,
      motionShort: motionShort ?? this.motionShort,
      motionLong: motionLong ?? this.motionLong,
    );
  }

  @override
  LudoBrand lerp(ThemeExtension<LudoBrand>? other, double t) {
    if (other is! LudoBrand) {
      return this;
    }
    return LudoBrand(
      action: Color.lerp(action, other.action, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      felt: Color.lerp(felt, other.felt, t)!,
      motionShort: t < 0.5 ? motionShort : other.motionShort,
      motionLong: t < 0.5 ? motionLong : other.motionLong,
    );
  }
}

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
    error: LudoColors.error,
  );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: LudoColors.paper,
    fontFamily: kLudoFontFamily,
    fontFamilyFallback: kLudoFontFallbacks,
    extensions: const <ThemeExtension<dynamic>>[LudoBrand.light],
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
        fontSize: kTypeTitle,
        color: LudoColors.ink,
      ),
    ),
    // AppBar only threads foreground into IconTheme / IconButtonTheme, never
    // TextButtonTheme — so a locale toggle TextButton must be set here once.
    // Disabled inkMuted keeps secondary actions AA on paper/surface.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        disabledForegroundColor: LudoColors.inkMuted,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LudoColors.action,
        foregroundColor: LudoColors.actionOn,
        // Explicit disabled ink so host Start waiting-reason stays ≥4.5:1
        // on paper/surface (Material's default 0.38 onSurface does not).
        disabledForegroundColor: LudoColors.inkMuted,
        disabledBackgroundColor: LudoColors.paperElevated,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusControl),
        ),
        textStyle: const TextStyle(
          fontFamily: kLudoFontFamily,
          fontFamilyFallback: kLudoFontFallbacks,
          fontWeight: FontWeight.w600,
          fontSize: kTypeLabel,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LudoColors.ink,
        disabledForegroundColor: LudoColors.inkMuted,
        side: const BorderSide(color: LudoColors.feltMid, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusControl),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LudoColors.paperElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: const BorderSide(color: LudoColors.feltLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(
          color: LudoColors.feltLight.withValues(alpha: 0.7),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: const BorderSide(color: LudoColors.action, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(color: scheme.error),
      ),
      labelStyle: const TextStyle(color: LudoColors.inkMuted),
      hintStyle: TextStyle(color: LudoColors.inkMuted.withValues(alpha: 0.7)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.comfortable,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusControl),
          ),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
      ),
    ),
  );
}

/// Neon underfelt arcade-night spike theme. Deep-void paper and cyan
/// action fringe; [LudoBrand.paper] diverges from Bold mint so contrast
/// gates cannot be satisfied by a mint alias.
ThemeData buildNeonUnderfeltTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: LudoColorsNeon.action,
    brightness: Brightness.dark,
    primary: LudoColorsNeon.action,
    onPrimary: LudoColorsNeon.actionOn,
    secondary: LudoColorsNeon.feltMid,
    onSecondary: LudoColorsNeon.ink,
    surface: LudoColorsNeon.paperElevated,
    onSurface: LudoColorsNeon.ink,
    error: LudoColorsNeon.error,
  );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: LudoColorsNeon.paper,
    fontFamily: kLudoFontFamily,
    fontFamilyFallback: kLudoFontFallbacks,
    extensions: const <ThemeExtension<dynamic>>[LudoBrand.neon],
  );

  return base.copyWith(
    textTheme: _ludoTextTheme(base.textTheme),
    primaryTextTheme: _ludoTextTheme(base.primaryTextTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: LudoColorsNeon.paperElevated,
      foregroundColor: LudoColorsNeon.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: kLudoFontFamily,
        fontFamilyFallback: kLudoFontFallbacks,
        fontWeight: FontWeight.w600,
        fontSize: kTypeTitle,
        color: LudoColorsNeon.ink,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        disabledForegroundColor: LudoColorsNeon.inkMuted,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LudoColorsNeon.action,
        foregroundColor: LudoColorsNeon.actionOn,
        disabledForegroundColor: LudoColorsNeon.inkMuted,
        disabledBackgroundColor: LudoColorsNeon.paperElevated,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusControl),
        ),
        textStyle: const TextStyle(
          fontFamily: kLudoFontFamily,
          fontFamilyFallback: kLudoFontFallbacks,
          fontWeight: FontWeight.w600,
          fontSize: kTypeLabel,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LudoColorsNeon.ink,
        disabledForegroundColor: LudoColorsNeon.inkMuted,
        side: const BorderSide(color: LudoColorsNeon.feltLight, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusControl),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LudoColorsNeon.paperElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: const BorderSide(color: LudoColorsNeon.feltLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(
          color: LudoColorsNeon.feltLight.withValues(alpha: 0.7),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: const BorderSide(color: LudoColorsNeon.action, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
        borderSide: BorderSide(color: scheme.error),
      ),
      labelStyle: const TextStyle(color: LudoColorsNeon.inkMuted),
      hintStyle: TextStyle(
        color: LudoColorsNeon.inkMuted.withValues(alpha: 0.7),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.comfortable,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusControl),
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LudoColorsNeon.actionOn;
          }
          return LudoColorsNeon.ink;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return LudoColorsNeon.action;
          }
          return LudoColorsNeon.paperElevated;
        }),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: LudoColorsNeon.action,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: LudoColorsNeon.feltDeep,
      contentTextStyle: const TextStyle(
        fontFamily: kLudoFontFamily,
        fontFamilyFallback: kLudoFontFallbacks,
        color: LudoColorsNeon.ink,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusControl),
      ),
    ),
  );
}

/// True when the active [LudoBrand] paper reads as deep-void (neon spike).
bool isNeonUnderfeltTheme(BuildContext context) {
  final LudoBrand? brand = Theme.of(context).extension<LudoBrand>();
  if (brand == null) {
    return false;
  }
  return ThemeData.estimateBrightnessForColor(brand.paper) == Brightness.dark;
}

Color ludoInkOf(BuildContext context) {
  return Theme.of(context).extension<LudoBrand>()?.ink ?? LudoColors.ink;
}

Color ludoPaperOf(BuildContext context) {
  return Theme.of(context).extension<LudoBrand>()?.paper ?? LudoColors.paper;
}

Color ludoInkMutedOf(BuildContext context) {
  return isNeonUnderfeltTheme(context)
      ? LudoColorsNeon.inkMuted
      : LudoColors.inkMuted;
}

Color ludoPaperElevatedOf(BuildContext context) {
  return isNeonUnderfeltTheme(context)
      ? LudoColorsNeon.paperElevated
      : LudoColors.paperElevated;
}

/// Full-bleed felt atmosphere used behind the home composition. A soft
/// vertical wash plus a faint grid so the screen does not read as a flat
/// fill, without competing with the die mark.
class FeltBackdrop extends StatelessWidget {
  const FeltBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool neon = isNeonUnderfeltTheme(context);
    final Color paper = ludoPaperOf(context);
    final List<Color> washes = neon
        ? <Color>[
            LudoColorsNeon.paperWashTop,
            paper,
            LudoColorsNeon.paperWashBottom,
          ]
        : <Color>[
            LudoColors.paperWashTop,
            LudoColors.paper,
            LudoColors.paperWashBottom,
          ];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: washes,
          stops: const <double>[0.0, 0.45, 1.0],
        ),
      ),
      child: CustomPaint(
        painter: _FeltGrainPainter(neon: neon),
        child: child,
      ),
    );
  }
}

class _FeltGrainPainter extends CustomPainter {
  const _FeltGrainPainter({required this.neon});

  final bool neon;

  @override
  void paint(Canvas canvas, Size size) {
    final Color mid = neon ? LudoColorsNeon.feltMid : LudoColors.feltMid;
    final Color light = neon ? LudoColorsNeon.feltLight : LudoColors.feltLight;
    final Paint line = Paint()
      ..color = mid.withValues(alpha: neon ? 0.08 : 0.045)
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
          light.withValues(alpha: neon ? 0.22 : 0.18),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wash);
  }

  @override
  bool shouldRepaint(covariant _FeltGrainPainter oldDelegate) =>
      oldDelegate.neon != neon;
}
