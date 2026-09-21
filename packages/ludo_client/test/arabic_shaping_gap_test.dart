// A measurement file, not a fit test. It exists to name a mechanism, not to
// pass or fail on a numeric threshold.
//
// work/ludo/orders/152-arabic-shaping-gap.md asks why a bare TextPainter in
// `flutter test`, fed the real Poppins/Noto Sans Arabic fonts through
// FontLoader and the app's real theme, measures the natural width of
// "4 لاعبين" (AppLocalizations.homePlayersFour, ar) at 51.70dp when run 47's
// master measured the same label's ink extent on a real device screenshot at
// 84.00dp -- a floor, since 84.00dp is ink extent and the true advance width
// is wider still. Geometry, Ahem substitution and the theme not being
// mounted are three already-dead hypotheses this file does not re-open (see
// the order's "already narrowed" section); this file's job is the fourth
// hypothesis the order opens: font weight availability/synthesis, plus the
// order's own two flag-shaped leads (`--use-test-fonts`,
// `--disable-asset-fonts`), tested one variable at a time against the
// selector's own resolved TextStyle, captured off a real mount rather than
// assumed.
//
// Every number below is printed by the case that measured it (Acceptance 1
// of the order). Nothing here is asserted against 84.00dp -- the order is
// explicit that a variation reaching it, or none of them reaching it, are
// both real findings to report, not something this file grades pass/fail.
// The `expect` calls in this file check that each measurement is well-formed
// (a finite, non-negative, non-NaN width, and, where the axis promises it,
// that varying the one named thing actually changed something rather than
// silently measuring the unchanged baseline twice), never that a number
// clears 84.00dp.
//
// Font manager mechanics cited in comments below (TestFontManager's
// "unmatched family name falls back to the first test font family",
// FontCollection::RegisterTestFonts calling DisableFontFallback,
// `--disable-asset-fonts` skipping FontCollection::RegisterFonts entirely)
// are read directly off this box's engine checkout under
// /workspace/toolchains/flutter/engine/src/flutter -- txt/src/txt/
// test_font_manager.cc, lib/ui/text/font_collection.cc, and
// shell/common/engine.cc -- not inferred from behaviour alone. The Skia
// skparagraph implementation that decides whether TextStyle.fontFamilyFallback
// itself is gated by that disabled-fallback flag is not vendored in this
// checkout (modules/skparagraph under third_party/skia here is a bare
// BUILD.gn with no sources), so this file cannot read that boundary directly
// and instead measures around it (the "primary family axis" group below).

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';

// The phone geometry the defect was photographed at (order 152's own table:
// 1080 / 2.75 = 392.73dp), the same pair
// test/home_screen_players_fit_test.dart and
// test/game_screen_token_label_fit_test.dart carry. Pinned here purely so
// the baseline mount below reproduces the order's own "pinned logical width,
// rig: 392.73dp" line from its own run, not so any wrapping is measured by
// this file (this file measures natural, unbounded widths only).
const Size _devicePhysicalSize = Size(1080, 1848);
const double _devicePixelRatio = 2.75;

/// One measured row of the table this file prints. Kept as a plain record
/// (not a class) so the summary group at the bottom can be a simple list
/// walk, not a second parallel accounting scheme.
typedef _Row = ({String axis, String variation, double naturalWidthDp});

/// Every row measured by this file, in the order measured. Populated by
/// each case as it runs (test files execute their top-level tests in
/// declaration order within one isolate) and read back by the final
/// "finding" group, which is declared last for exactly that reason.
final List<_Row> _rows = <_Row>[];

void _record(String axis, String variation, double naturalWidthDp) {
  _rows.add((axis: axis, variation: variation, naturalWidthDp: naturalWidthDp));
  // Proof for the record, not decoration: printed by the case that measured
  // it, per the order's Acceptance 1 ("each printed by the test itself so
  // the reviewer can re-run it and read the same numbers").
  // ignore: avoid_print
  print(
    'arabic_shaping_gap table row: axis=$axis variation="$variation" '
    'naturalWidth=${naturalWidthDp}dp deviceInkFloor=84.00dp '
    'reachesFloor=${naturalWidthDp >= 84.00}',
  );
}

/// Loads every font weight the theme's `fontFamily`/`fontFamilyFallback`
/// pair asks for (lib/src/theme.dart `kLudoFontFamily` = 'Poppins',
/// `kLudoFontFallbacks` = ['Noto Sans Arabic']), copied from this package's
/// own pubspec.yaml `flutter: fonts:` block exactly as
/// test/home_screen_players_fit_test.dart's own `_loadAppFonts` does, plus
/// two extra aliases this file alone needs: the same Noto Sans Arabic
/// glyph outlines registered a second and third time under family names
/// that carry only one weight file each, so a case can ask for weight 600
/// against a family that never had 600 (or even 700) available to it,
/// isolating whether the number of weight files a family was loaded with
/// changes the advance width the engine produces for a weight none of them
/// natively carry -- the order's standing suspect.
///
/// `TestWidgetsFlutterBinding.ensureInitialized()` is called explicitly
/// before the first `rootBundle.load` below for the same reason
/// home_screen_players_fit_test.dart's `_loadAppFonts` calls it: this runs
/// from `setUpAll`, outside any `testWidgets` body, and nothing guarantees a
/// binding exists yet the first time `setUpAll` fires.
Future<void> _loadFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader notoSansArabicBoth = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabicBoth.addFont(rootBundle.load(asset));
  }
  await notoSansArabicBoth.load();

  final FontLoader notoSansArabicOnly400 = FontLoader(
    'Noto Sans Arabic Only400',
  );
  notoSansArabicOnly400.addFont(
    rootBundle.load('fonts/NotoSansArabic-Regular.ttf'),
  );
  await notoSansArabicOnly400.load();

  final FontLoader notoSansArabicOnly700 = FontLoader(
    'Noto Sans Arabic Only700',
  );
  notoSansArabicOnly700.addFont(
    rootBundle.load('fonts/NotoSansArabic-Bold.ttf'),
  );
  await notoSansArabicOnly700.load();
}

/// A from-scratch `TextPainter` measurement of [text] at [style], laid out
/// with no width limit at all -- run 47's own methodology (bare TextPainter,
/// not through the screen) and the same technique
/// test/home_screen_players_fit_test.dart's `_naturalWidthOf` uses.
double _naturalWidthOf(
  String text,
  TextStyle style,
  TextDirection direction, {
  TextScaler? textScaler,
}) {
  final TextPainter probe = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: textScaler ?? TextScaler.noScaling,
  )..layout();
  try {
    return probe.width;
  } finally {
    probe.dispose();
  }
}

/// Pins `tester.view` to the phone geometry the defect was photographed at
/// and returns the logical width that geometry resolves to, matching
/// test/home_screen_players_fit_test.dart's `_pinPhoneView`.
double _pinPhoneView(WidgetTester tester) {
  tester.view.physicalSize = _devicePhysicalSize;
  tester.view.devicePixelRatio = _devicePixelRatio;
  addTearDown(tester.view.reset);
  return _devicePhysicalSize.width / _devicePixelRatio;
}

/// A [RoomControllerFactory]-shaped function that never opens a transport,
/// real or fake -- copied from test/home_screen_players_fit_test.dart's own
/// `_neverConnectsControllerFactory` for the same reason: this file taps
/// nothing that opens a room, so nothing should ever call this.
RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://arabic-shaping-gap-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'arabic_shaping_gap_test.dart: this connector must never be asked '
        'to open a real or fake transport; this file never taps Create '
        'Room or Join Room, so nothing should ever call it',
      );
    },
  );
}

/// The app's own real theme (lib/src/theme.dart `buildAppTheme()`), same
/// scaffolding test/home_screen_players_fit_test.dart and
/// integration_test/screenshots_test.dart build, so the baseline TextStyle
/// this file captures is the one a player's phone actually resolves, not a
/// bare MaterialApp's Material 3 defaults.
Widget _harness(Locale locale) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _neverConnectsControllerFactory,
    ),
  );
}

/// Mounts HomeScreen at [locale] and opens the seat-count selector, matching
/// test/home_screen_players_fit_test.dart's `_mount` /
/// `_openPlayersDisclosure` (bounded pumps only, no pumpAndSettle -- see that
/// file's comment for why).
Future<void> _mount(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(_harness(locale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));

  final Finder disclosure = find.byKey(const Key('home-players-disclosure'));
  expect(
    disclosure,
    findsOneWidget,
    reason:
        'fixture is broken: home-players-disclosure must be on screen so '
        'this file can open the seat-count selector it measures',
  );
  await tester.tap(disclosure);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    _selectorFinder,
    findsOneWidget,
    reason: 'tapping home-players-disclosure must reveal home-players-selector',
  );
}

final Finder _selectorFinder = find.byKey(const Key('home-players-selector'));

Finder _segmentLabelFinder(String label) =>
    find.descendant(of: _selectorFinder, matching: find.text(label));

Future<void> _selectByTap(WidgetTester tester, String label) async {
  final Finder finder = _segmentLabelFinder(label);
  expect(
    finder,
    findsOneWidget,
    reason:
        'fixture is broken: no segment in the player-count selector '
        'carries the label "$label"',
  );
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Finds the single `RichText` painting the label of the segment carrying
/// [label], and returns the live `RenderParagraph` behind it -- same
/// technique as test/home_screen_players_fit_test.dart's
/// `_paragraphOfSegmentLabel`.
RenderParagraph _paragraphOfSegmentLabel(WidgetTester tester, String label) {
  final Finder labelFinder = _segmentLabelFinder(label);
  expect(
    labelFinder,
    findsOneWidget,
    reason:
        'fixture is broken: no segment in the player-count selector '
        'carries the label "$label"',
  );
  final Finder textFinder = find.descendant(
    of: labelFinder,
    matching: find.byType(RichText),
  );
  expect(
    textFinder,
    findsOneWidget,
    reason:
        'fixture is broken: expected exactly one RichText under the '
        '"$label" segment label',
  );
  return tester.renderObject<RenderParagraph>(textFinder);
}

/// Every TextStyle field a `TextPainter` measurement in this file needs to
/// reproduce the selector's real resolved style, captured off a live
/// `RenderParagraph` rather than typed in by hand: fontFamily,
/// fontFamilyFallback, fontWeight, fontSize, letterSpacing and height. Color
/// is deliberately excluded -- it plays no part in advance-width
/// measurement, and it is the one field the theme (segmentedButtonTheme,
/// lib/src/theme.dart) actually does vary by selection state, so a resolved
/// style comparison that included it would trivially "differ" for a reason
/// this file does not care about.
typedef _CapturedStyle = ({
  String? fontFamily,
  List<String>? fontFamilyFallback,
  FontWeight? fontWeight,
  double? fontSize,
  double? letterSpacing,
  double? height,
});

_CapturedStyle _capture(TextStyle style) => (
  fontFamily: style.fontFamily,
  fontFamilyFallback: style.fontFamilyFallback,
  fontWeight: style.fontWeight,
  fontSize: style.fontSize,
  letterSpacing: style.letterSpacing,
  height: style.height,
);

/// [overrideWeight] distinguishes "caller did not ask to touch the weight,
/// keep the captured one" from "caller wants exactly [weight] (which may
/// itself be null, meaning no fontWeight set at all)" -- `TextStyle.
/// copyWith` cannot express the second case on its own (a null argument to
/// `copyWith` means "keep the existing value", not "clear it"), which is
/// exactly the "no weight set" variation this file's fontWeight axis needs
/// to be able to express.
TextStyle _styleFrom(
  _CapturedStyle c, {
  bool overrideWeight = false,
  FontWeight? weight,
}) {
  return TextStyle(
    fontFamily: c.fontFamily,
    fontFamilyFallback: c.fontFamilyFallback,
    fontWeight: overrideWeight ? weight : c.fontWeight,
    fontSize: c.fontSize,
    letterSpacing: c.letterSpacing,
    height: c.height,
  );
}

void main() {
  setUpAll(_loadFonts);

  late _CapturedStyle baselineStyle;
  late String label;
  late TextDirection labelDirection;
  late TextScaler mountedTextScaler;

  group('baseline: the selector\'s real resolved TextStyle for "4 لاعبين", '
      'captured off the live mount rather than assumed (order 152)', () {
    testWidgets('captures fontFamily/fontFamilyFallback/fontWeight/fontSize/'
        'letterSpacing/height/textDirection/textScaler off the '
        '4-players Arabic segment\'s RenderParagraph, in both selection '
        'states', (tester) async {
      final double logicalWidth = _pinPhoneView(tester);
      await _mount(tester, const Locale('ar'));
      final BuildContext context = tester.element(find.byType(Scaffold));
      final AppLocalizations loc = AppLocalizations.of(context);
      label = loc.homePlayersFour;
      final String otherLabel = loc.homePlayersTwo;

      // Select 4 players so the 4-players segment is the selected one.
      await _selectByTap(tester, label);
      final RenderParagraph selectedParagraph = _paragraphOfSegmentLabel(
        tester,
        label,
      );
      final TextStyle? selectedStyle = selectedParagraph.text.style;
      expect(
        selectedStyle,
        isNotNull,
        reason:
            'fixture is broken: the 4-players segment label\'s '
            'RenderParagraph carries a null style while selected',
      );

      // Select 2 players so the 4-players segment becomes unselected.
      await _selectByTap(tester, otherLabel);
      final RenderParagraph unselectedParagraph = _paragraphOfSegmentLabel(
        tester,
        label,
      );
      final TextStyle? unselectedStyle = unselectedParagraph.text.style;
      expect(
        unselectedStyle,
        isNotNull,
        reason:
            'fixture is broken: the 4-players segment label\'s '
            'RenderParagraph carries a null style while unselected',
      );

      labelDirection = unselectedParagraph.textDirection;
      mountedTextScaler = unselectedParagraph.textScaler;

      final _CapturedStyle capturedSelected = _capture(selectedStyle!);
      final _CapturedStyle capturedUnselected = _capture(unselectedStyle!);

      // ignore: avoid_print
      print(
        'arabic_shaping_gap baseline: label="$label" '
        'pinnedLogicalWidth=${logicalWidth.toStringAsFixed(2)}dp '
        'textDirection=$labelDirection '
        'mountedTextScaler=$mountedTextScaler\n'
        '  selected style:   fontFamily=${capturedSelected.fontFamily} '
        'fontFamilyFallback=${capturedSelected.fontFamilyFallback} '
        'fontWeight=${capturedSelected.fontWeight} '
        'fontSize=${capturedSelected.fontSize} '
        'letterSpacing=${capturedSelected.letterSpacing} '
        'height=${capturedSelected.height} '
        'color=${selectedStyle.color}\n'
        '  unselected style: fontFamily=${capturedUnselected.fontFamily} '
        'fontFamilyFallback=${capturedUnselected.fontFamilyFallback} '
        'fontWeight=${capturedUnselected.fontWeight} '
        'fontSize=${capturedUnselected.fontSize} '
        'letterSpacing=${capturedUnselected.letterSpacing} '
        'height=${capturedUnselected.height} '
        'color=${unselectedStyle.color}',
      );

      // The order's "strongest clue on the table": the rig measures the
      // selected and unselected Arabic segment at an identical 51.70dp,
      // read as possible evidence the rig ignores the selected
      // segment's own TextStyle. What this file finds instead: the
      // theme (segmentedButtonTheme, lib/src/theme.dart) never sets a
      // labelStyle that varies by WidgetState.selected in the first
      // place -- only foregroundColor/backgroundColor do. So the two
      // resolved styles are expected to be identical in every field
      // that could move an advance width, checked directly here rather
      // than inferred from the width match alone. fontFamilyFallback is
      // compared with listEquals, not record `==`: Dart record equality
      // compares each field with `==`, and List's own `==` is identity,
      // not content, so a naive record comparison could read two
      // content-identical but distinct List instances as "different"
      // (or silently pass only because the theme happens to reuse one
      // constant list instance, which is not a fact this file wants
      // hidden behind Dart's default equality).
      expect(
        capturedSelected.fontFamily,
        capturedUnselected.fontFamily,
        reason:
            'expected the 4-players segment\'s resolved fontFamily to '
            'be identical whether the segment is selected or not',
      );
      expect(
        listEquals(
          capturedSelected.fontFamilyFallback,
          capturedUnselected.fontFamilyFallback,
        ),
        isTrue,
        reason:
            'expected the 4-players segment\'s resolved '
            'fontFamilyFallback to be identical whether the segment is '
            'selected (${capturedSelected.fontFamilyFallback}) or not '
            '(${capturedUnselected.fontFamilyFallback})',
      );
      expect(
        capturedSelected.fontWeight,
        capturedUnselected.fontWeight,
        reason:
            'expected the 4-players segment\'s resolved fontWeight to '
            'be identical whether the segment is selected or not',
      );
      expect(
        capturedSelected.fontSize,
        capturedUnselected.fontSize,
        reason:
            'expected the 4-players segment\'s resolved fontSize to be '
            'identical whether the segment is selected or not',
      );
      expect(
        capturedSelected.letterSpacing,
        capturedUnselected.letterSpacing,
        reason:
            'expected the 4-players segment\'s resolved letterSpacing '
            'to be identical whether the segment is selected or not',
      );
      expect(
        capturedSelected.height,
        capturedUnselected.height,
        reason:
            'expected the 4-players segment\'s resolved height to be '
            'identical whether the segment is selected or not',
      );
      // lib/src/theme.dart's segmentedButtonTheme only varies
      // foregroundColor/backgroundColor by WidgetState.selected, never
      // labelStyle -- if every field above matches (it does, this
      // point is only reached when all five pass) then a difference in
      // color and nowhere else is expected, not a fixture defect. This
      // is documented, not asserted: a fix that also started colouring
      // the label some other way would not be a shaping regression.
      // ignore: avoid_print
      print(
        'arabic_shaping_gap baseline: selected vs unselected color '
        'differs=${selectedStyle.color != unselectedStyle.color} '
        '(selected=${selectedStyle.color}, '
        'unselected=${unselectedStyle.color})',
      );

      final double naturalWidthSelected = _naturalWidthOf(
        label,
        selectedStyle,
        labelDirection,
        textScaler: mountedTextScaler,
      );
      final double naturalWidthUnselected = _naturalWidthOf(
        label,
        unselectedStyle,
        labelDirection,
        textScaler: mountedTextScaler,
      );
      _record('baseline (selected)', 'theme default', naturalWidthSelected);
      _record('baseline (unselected)', 'theme default', naturalWidthUnselected);

      baselineStyle = capturedUnselected;

      expect(
        naturalWidthSelected.isFinite && naturalWidthSelected > 0,
        isTrue,
        reason:
            'the selected-state natural width measured '
            '$naturalWidthSelected, which is not a usable positive '
            'finite measurement',
      );

      tester.view.reset();
    });
  });

  group('fontWeight axis: same family/fallback/size, only fontWeight varies '
      '(order 152 bullet 1 -- the standing suspect: the theme asks for 600, '
      'Noto Sans Arabic ships only 400 and 700)', () {
    for (final FontWeight? weight in const <FontWeight?>[
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
      null,
    ]) {
      final String label600 = weight?.toString() ?? 'unset';
      testWidgets('fontWeight=$label600', (tester) async {
        final TextStyle style = _styleFrom(
          baselineStyle,
          overrideWeight: true,
          weight: weight,
        );
        final double width = _naturalWidthOf(
          label,
          style,
          labelDirection,
          textScaler: mountedTextScaler,
        );
        _record('fontWeight', label600, width);
        expect(
          width.isFinite && width > 0,
          isTrue,
          reason:
              'fontWeight=$label600: natural width measured $width, '
              'which is not a usable positive finite measurement',
        );
      });
    }

    testWidgets('w700 measures no narrower than w400 (a real proportional font '
        'never gets narrower at a heavier weight)', (tester) async {
      final double w400 = _naturalWidthOf(
        label,
        _styleFrom(
          baselineStyle,
          overrideWeight: true,
          weight: FontWeight.w400,
        ),
        labelDirection,
        textScaler: mountedTextScaler,
      );
      final double w700 = _naturalWidthOf(
        label,
        _styleFrom(
          baselineStyle,
          overrideWeight: true,
          weight: FontWeight.w700,
        ),
        labelDirection,
        textScaler: mountedTextScaler,
      );
      // ignore: avoid_print
      print(
        'arabic_shaping_gap fontWeight monotonicity check: w400='
        '${w400}dp w700=${w700}dp',
      );
      expect(
        w700,
        greaterThanOrEqualTo(w400),
        reason:
            'w400 measured ${w400}dp and w700 measured ${w700}dp; a '
            'heavier weight of a real proportional font must not '
            'measure narrower than a lighter weight of the same font '
            '(w700 < w400 here would mean the weight axis is not doing '
            'what it says, e.g. because the family behind it only ever '
            'resolves to a single fixed-width substitute regardless of '
            'the requested weight)',
      );
    });
  });

  group('FontLoader registration axis: the Arabic fallback family loaded with '
      'only the 400 file, only the 700 file, and both, all measured at the '
      'theme\'s own weight 600 (order 152 bullet 2 -- the fallback family '
      'never had a 600 file under any of these three registrations, so this '
      'isolates whether the number of weight files present changes what the '
      'engine produces for a weight none of them natively carry)', () {
    const Map<String, String> familyByRegistration = <String, String>{
      'only 400 file registered': 'Noto Sans Arabic Only400',
      'only 700 file registered': 'Noto Sans Arabic Only700',
      'both 400 and 700 registered': 'Noto Sans Arabic',
    };

    for (final MapEntry<String, String> entry in familyByRegistration.entries) {
      testWidgets(entry.key, (tester) async {
        final TextStyle style = TextStyle(
          fontFamily: baselineStyle.fontFamily,
          fontFamilyFallback: <String>[entry.value],
          fontWeight: FontWeight.w600,
          fontSize: baselineStyle.fontSize,
          letterSpacing: baselineStyle.letterSpacing,
          height: baselineStyle.height,
        );
        final double width = _naturalWidthOf(
          label,
          style,
          labelDirection,
          textScaler: mountedTextScaler,
        );
        _record(
          'FontLoader registration (fallback=${entry.value})',
          entry.key,
          width,
        );
        expect(
          width.isFinite && width > 0,
          isTrue,
          reason:
              '${entry.key}: natural width measured $width, which is '
              'not a usable positive finite measurement',
        );
      });
    }
  });

  group(
    'primary family axis: Poppins primary with Noto Sans Arabic fallback '
    '(the theme\'s actual configuration) against Noto Sans Arabic as the '
    'sole primary family, no fallback list at all (order 152 bullet 3 -- '
    'this is also the control the order\'s second clue names as the first '
    'one to run: whether the digit "4" resolving to the primary family '
    'while the Arabic word falls through to the fallback family measures '
    'differently from a single uniform family covering the whole string)',
    () {
      testWidgets('Poppins primary, Noto Sans Arabic fallback (current theme '
          'configuration, weight 600)', (tester) async {
        final TextStyle style = TextStyle(
          fontFamily: 'Poppins',
          fontFamilyFallback: const <String>['Noto Sans Arabic'],
          fontWeight: FontWeight.w600,
          fontSize: baselineStyle.fontSize,
          letterSpacing: baselineStyle.letterSpacing,
          height: baselineStyle.height,
        );
        final double width = _naturalWidthOf(
          label,
          style,
          labelDirection,
          textScaler: mountedTextScaler,
        );
        _record(
          'primary family',
          'Poppins primary + Noto Sans Arabic fallback',
          width,
        );
        expect(
          width.isFinite && width > 0,
          isTrue,
          reason:
              'Poppins primary + Noto Sans Arabic fallback: natural '
              'width measured $width, which is not a usable positive '
              'finite measurement',
        );
      });

      testWidgets(
        'Noto Sans Arabic as the sole primary family, no fallback list '
        '(weight 600)',
        (tester) async {
          final TextStyle style = TextStyle(
            fontFamily: 'Noto Sans Arabic',
            fontWeight: FontWeight.w600,
            fontSize: baselineStyle.fontSize,
            letterSpacing: baselineStyle.letterSpacing,
            height: baselineStyle.height,
          );
          final double width = _naturalWidthOf(
            label,
            style,
            labelDirection,
            textScaler: mountedTextScaler,
          );
          _record(
            'primary family',
            'Noto Sans Arabic sole primary, no fallback',
            width,
          );
          expect(
            width.isFinite && width > 0,
            isTrue,
            reason:
                'Noto Sans Arabic sole primary, no fallback: natural width '
                'measured $width, which is not a usable positive finite '
                'measurement',
          );
        },
      );
    },
  );

  group('textScaler axis: 1.0 expressed three different ways, to check '
      'whether the rig and a real device could disagree about scale rather '
      'than about the font itself (order 152 bullet 4)', () {
    testWidgets('no textScaler argument passed at all (TextPainter default)', (
      tester,
    ) async {
      final TextStyle style = _styleFrom(baselineStyle);
      final TextPainter probe = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: labelDirection,
      )..layout();
      final double width = probe.width;
      probe.dispose();
      _record('textScaler', 'no argument passed (TextPainter default)', width);
      expect(
        width.isFinite && width > 0,
        isTrue,
        reason:
            'no textScaler argument: natural width measured $width, '
            'which is not a usable positive finite measurement',
      );
    });

    testWidgets('TextScaler.noScaling, explicit', (tester) async {
      final TextStyle style = _styleFrom(baselineStyle);
      final double width = _naturalWidthOf(
        label,
        style,
        labelDirection,
        textScaler: TextScaler.noScaling,
      );
      _record('textScaler', 'TextScaler.noScaling, explicit', width);
      expect(
        width.isFinite && width > 0,
        isTrue,
        reason:
            'TextScaler.noScaling: natural width measured $width, which '
            'is not a usable positive finite measurement',
      );
    });

    testWidgets('TextScaler.linear(1.0), explicit', (tester) async {
      final TextStyle style = _styleFrom(baselineStyle);
      final double width = _naturalWidthOf(
        label,
        style,
        labelDirection,
        textScaler: const TextScaler.linear(1.0),
      );
      _record('textScaler', 'TextScaler.linear(1.0), explicit', width);
      expect(
        width.isFinite && width > 0,
        isTrue,
        reason:
            'TextScaler.linear(1.0): natural width measured $width, '
            'which is not a usable positive finite measurement',
      );
    });

    testWidgets(
      'all three textScaler expressions of 1.0 measure the same width',
      (tester) async {
        final TextStyle style = _styleFrom(baselineStyle);
        final double a = _naturalWidthOf(label, style, labelDirection);
        final double b = _naturalWidthOf(
          label,
          style,
          labelDirection,
          textScaler: TextScaler.noScaling,
        );
        final double c = _naturalWidthOf(
          label,
          style,
          labelDirection,
          textScaler: const TextScaler.linear(1.0),
        );
        // ignore: avoid_print
        print(
          'arabic_shaping_gap textScaler agreement check: default='
          '${a}dp noScaling=${b}dp linear1.0=${c}dp',
        );
        expect(
          a,
          b,
          reason:
              'TextPainter default width (${a}dp) and TextScaler.'
              'noScaling width (${b}dp) disagree; both are meant to be '
              'the same no-op scale',
        );
        expect(
          b,
          c,
          reason:
              'TextScaler.noScaling width (${b}dp) and TextScaler.'
              'linear(1.0) width (${c}dp) disagree; both are meant to be '
              'the same no-op scale',
        );
      },
    );
  });

  group('finding: which variation, if any, reaches the device ink floor of '
      '84.00dp (order 152 Acceptance 2)', () {
    test('prints the full table and states the plain finding', () {
      expect(
        _rows,
        isNotEmpty,
        reason:
            'fixture is broken: no earlier group in this file recorded a '
            'row, so there is nothing for this closing group to '
            'summarise; every testWidgets case above calls _record before '
            'this test runs, and package:test runs a single file\'s top '
            'level tests in declaration order within one isolate',
      );

      final StringBuffer table = StringBuffer(
        'arabic_shaping_gap full table (${_rows.length} rows):\n',
      );
      for (final _Row row in _rows) {
        table.writeln(
          '  axis=${row.axis} variation="${row.variation}" '
          'naturalWidth=${row.naturalWidthDp}dp',
        );
      }
      // ignore: avoid_print
      print(table.toString());

      final List<_Row> reachingFloor = _rows
          .where((_Row r) => r.naturalWidthDp >= 84.00)
          .toList();
      final _Row widest = _rows.reduce(
        (_Row a, _Row b) => a.naturalWidthDp >= b.naturalWidthDp ? a : b,
      );

      final String finding = reachingFloor.isEmpty
          ? 'arabic_shaping_gap finding: no variation measured by this '
                'file reached the device ink floor of 84.00dp for '
                '"$label". Highest measured: ${widest.naturalWidthDp}dp '
                '(${widest.axis}: "${widest.variation}"). This is a null '
                'result and is reported as one: none of font weight, '
                'weight-file registration count, primary family choice '
                'or textScaler expression closes the gap this order '
                'measures, at least not on its own and not at the '
                'increments tested here.'
          : 'arabic_shaping_gap finding: ${reachingFloor.length} '
                'variation(s) reached or exceeded the device ink floor of '
                '84.00dp for "$label": '
                '${reachingFloor.map((_Row r) => '${r.axis}="${r.variation}" (${r.naturalWidthDp}dp)').join(', ')}.';
      // ignore: avoid_print
      print(finding);
    });
  });
}
