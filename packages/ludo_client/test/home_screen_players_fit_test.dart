// A proof, independent of lib/src/home_screen.dart's own author, that every
// segment of the player-count selector on HomeScreen
// (work/ludo/orders/147-players-selector-fit-proof.md, respec'd by
// work/ludo/orders/148-players-selector-fit-proof-real-fonts.md) lays its
// label out on a single line at a real phone width, in both languages this
// app ships, and for every selection a player can put the control in.
//
// This file is order 147's file, respec'd. 147's own file is preserved,
// unmerged, on origin/order/147-wt at 05004e7, and its worker found exactly
// why its own numbers were not evidence: `flutter_test` renders every
// widget test's text with the substitute "Ahem" font (flutter_test's own
// matchers.dart: "By default, the Flutter framework uses a font called
// 'Ahem' which shows..."), which gives every character an identical fixed
// square glyph as wide as the font size, not the Poppins (Latin) and Noto
// Sans Arabic (Arabic fallback) this app actually ships
// (packages/ludo_client/pubspec.yaml `flutter: fonts:`). At Ahem's metrics,
// "2 players" wants about 127dp against the roughly 61-91dp-wide segments
// this control lays out, so under Ahem every English segment wraps
// regardless of whether the real font does, and the selected-versus-
// unselected difference the original defect was actually made of
// disappears into that noise. 16 of 147's 18 cases were red for that
// reason and none of that red was evidence of anything about this control.
//
// What is different here, per order 148: `setUpAll` below loads every font
// weight the theme's `fontFamily`/`fontFamilyFallback` pair
// (lib/src/theme.dart's `kLudoFontFamily` = 'Poppins',
// `kLudoFontFallbacks` = ['Noto Sans Arabic']) asks for, straight off the
// same asset paths pubspec.yaml declares, before any test in this file
// mounts anything. And every mount below happens inside
// `MaterialApp(theme: buildAppTheme(), ...)`, the app's own real theme
// (lib/src/theme.dart), the same scaffolding
// integration_test/screenshots_test.dart builds -- not a bare `MaterialApp`
// with no `theme:`, which would render Material 3's own default text theme
// and default `SegmentedButtonThemeData` (no `visualDensity: comfortable`,
// no felt-teal selected fill), neither of which is what a player's phone
// actually shows.
//
// How this file confirms the fonts it loaded are actually in effect, not
// merely requested: the "sanity" group below measures, with a bare
// `TextPainter` fed nothing but a `TextStyle(fontFamily: 'Poppins', ...)`
// or `TextStyle(fontFamily: 'Noto Sans Arabic', ...)` and no live render
// tree at all, two different strings of equal character count and asserts
// their natural single-line widths differ. Under Ahem this can never
// happen -- Ahem's glyphs are identical squares regardless of which
// character they represent, so any two same-length strings measure
// identically under it, exactly and not approximately. Poppins and Noto
// Sans Arabic are ordinary proportional fonts, so a narrow-shaped run
// ("i" x10) and a wide-shaped run ("W" x10) measuring the same width would
// mean the substitute font was still in effect despite the `FontLoader`
// calls in `setUpAll` having run and returned without error. A third
// sanity case mounts English `HomeScreen` for real and reads the resolved
// `TextStyle` straight off the selected segment's own `RenderParagraph`,
// checking `fontFamily == 'Poppins'` and `fontFamilyFallback` containing
// 'Noto Sans Arabic' -- the check order 146's worker used, applied here to
// this control specifically, as a second, independent confirmation that
// the theme this file mounts inside is actually wiring the loaded fonts to
// the widget under test rather than to some other part of the tree.
//
// Distinguishability, the try/finally around the SemanticsHandle, the
// per-(locale, selection, measured segment) case shape (18 independent
// cases rather than one looping case per selection state), the
// RenderParagraph -> fresh-TextPainter line-count reconstruction technique
// (RenderParagraph exposes no line-metrics accessor of its own on this
// SDK), and the deliberate omissions (no literal wording asserted, no
// RenderFlex-overflow watched for, no selected-segment icon asserted) are
// all kept exactly as order 147's file had them; see that file
// (origin/order/147-wt at 05004e7) for the fuller argument behind each,
// repeated here only where this file's own behaviour differs from it.
//
// Deliberately not asserted: the literal wording ("4 players", "لاعبين").
// A fix for this defect is free to reword the label; a test that
// hardcoded the current string would fail the moment that happens, for a
// reason that has nothing to do with whether the label fits. Every label
// this file measures or taps is read back off AppLocalizations through the
// mounted tree's own BuildContext, never typed in here as a literal.
//
// Deliberately not asserted: the selected-segment checkmark icon, present
// or absent. Order 146 (`showSelectedIcon: false`) is merged on the base
// this file runs against, but the property this file asserts instead --
// `SemanticsFlag.isSelected` on the merged Semantics node
// `SegmentedButton` wraps every segment in
// (flutter/src/material/segmented_button.dart), computed directly off the
// widget's own `selected` set -- does not pin that one particular fix and
// would keep working under a future one that solves selection legibility
// some other way.
//
// Deliberately not asserted: a RenderFlex "overflowed" exception. The
// label wraps inside its box and never spills past it, so no such
// exception is ever thrown here, on fixed or unfixed code, and a test
// watching for one would pass on a build that still wraps.

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

// The phone geometry the defect was photographed at (screenshots.yml run 13,
// 01-home-en.png / 02-home-ar.png), the same pair
// test/game_screen_token_label_fit_test.dart:108-109 carries.
const Size _devicePhysicalSize = Size(1080, 1848);
const double _devicePixelRatio = 2.75;

// --- real fonts, loaded once for the whole file -----------------------

/// Every font asset and family name below is copied from this package's own
/// `pubspec.yaml` `flutter: fonts:` block, not invented here: 'Poppins' at
/// weights 400/500/600/700 under fonts/Poppins-*.ttf, and 'Noto Sans
/// Arabic' at weights 400/700 under fonts/NotoSansArabic-*.ttf -- the same
/// two family names lib/src/theme.dart's `kLudoFontFamily` and
/// `kLudoFontFallbacks` name.
///
/// `TestWidgetsFlutterBinding.ensureInitialized()` is called explicitly
/// before the first `rootBundle.load` below because this runs from
/// `setUpAll`, outside any `testWidgets` body -- `testWidgets` itself
/// guarantees a binding by the time its own callback runs, but nothing
/// guarantees one exists yet the first time `setUpAll` fires.
Future<void> _loadAppFonts() async {
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

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

/// A from-scratch `TextPainter` measurement of [text] at [style], laid out
/// with no width limit at all -- unlike every other measurement in this
/// file, this one is not reconstructed off a live `RenderParagraph`,
/// because the whole point of the "sanity" group below is to measure a
/// string this file made up, before or independent of any widget mount, so
/// there is no render object to read it off.
double _naturalWidthOf(String text, TextStyle style, TextDirection direction) {
  final TextPainter probe = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
  )..layout();
  try {
    return probe.width;
  } finally {
    probe.dispose();
  }
}

/// Pins `tester.view` to the phone geometry the defect was photographed at
/// and returns the logical width that geometry resolves to, so a failure
/// message can state it.
///
/// `addTearDown(tester.view.reset)` is the safety net for a body that throws
/// before reaching its own explicit `tester.view.reset()` call at the end
/// (see every test below): that explicit call is a second, earlier point of
/// restoration on the path where nothing throws, so this file does not rely
/// on `addTearDown` alone to keep a pinned geometry from one test leaking
/// into the next.
double _pinPhoneView(WidgetTester tester) {
  tester.view.physicalSize = _devicePhysicalSize;
  tester.view.devicePixelRatio = _devicePixelRatio;
  addTearDown(tester.view.reset);
  return _devicePhysicalSize.width / _devicePixelRatio;
}

/// A [RoomControllerFactory]-shaped function (`RoomController Function()`,
/// lib/src/server_config.dart) that never opens a transport, real or fake.
/// Nothing in this file ever taps Create Room or Join Room, so nothing
/// should ever call this; it exists only so HomeScreen has something safe to
/// hold instead of defaultRoomControllerFactory, which opens a real socket
/// against a production address the moment it is actually used.
RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-screen-players-fit-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_screen_players_fit_test.dart: this connector must never be '
        'asked to open a real or fake transport; this file never taps '
        'Create Room or Join Room, so nothing should ever call it',
      );
    },
  );
}

/// The app's own real theme (lib/src/theme.dart `buildAppTheme()`), not a
/// bare `MaterialApp` with no `theme:`. A bare `MaterialApp` renders
/// Material 3's own defaults -- no `SegmentedButtonThemeData` with
/// `visualDensity: comfortable`, no felt-teal seeded `ColorScheme`, no
/// `kLudoFontFamily` default -- none of which is what a player's phone
/// shows, so a proof mounted without it would still not be measuring the
/// real control. Same scaffolding integration_test/screenshots_test.dart's
/// `_ScreenshotHarness` builds.
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

/// Mounts HomeScreen at [locale] and pumps past `_HomeScreenState._enter`'s
/// 900ms entrance AnimationController with a single bounded pump rather than
/// `pumpAndSettle`. Nothing pushed by this file is a LobbyScreen or a live
/// countdown, so `pumpAndSettle` would in fact return here, but the package
/// idiom (see this order's standing rules) is a bounded `pump()` regardless,
/// so this file does not become the one place that quietly depends on
/// `pumpAndSettle` terminating.
Future<void> _mount(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(_harness(locale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
  await _openPlayersDisclosure(tester);
}

/// Opens the seat-count selector. It stays hidden until the player taps
/// home-players-disclosure; every measurement in this file is of that
/// selector, so the mount must open it. Bounded pumps only, matching
/// [_mount] (see that comment for why not pumpAndSettle).
Future<void> _openPlayersDisclosure(WidgetTester tester) async {
  final Finder disclosure = find.byKey(const Key('home-players-disclosure'));
  expect(
    disclosure,
    findsOneWidget,
    reason:
        'fixture is broken: home-players-disclosure must be on screen '
        'so this file can open the seat-count selector it measures',
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

/// The mounted `Text` widget carrying [label], scoped to descend from the
/// player-count selector. [label] is always read off `AppLocalizations` by
/// the caller, never typed as a literal in this file (see the file header).
Finder _segmentLabelFinder(String label) =>
    find.descendant(of: _selectorFinder, matching: find.text(label));

/// Taps the segment carrying [label] the way a player does -- a real tap
/// on the label text inside the selector -- rather than by reaching into
/// `_HomeScreenState`'s private `_players` field.
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
  // SegmentedButton's own selection-change animation; 400ms is comfortably
  // past it without reaching for pumpAndSettle (see _mount).
  await tester.pump(const Duration(milliseconds: 400));
}

/// Whether the segment carrying [label] is the selected one, read off the
/// merged Semantics node `SegmentedButton` wraps every segment in
/// (flutter/src/material/segmented_button.dart:632-638:
/// `MergeSemantics(child: Semantics(selected: segmentSelected, ...))`,
/// computed directly off the widget's own `selected` set). This is the
/// property this file asserts the selected segment is distinguishable by:
/// it belongs to `SegmentedButton` itself, is set independently of whichever
/// icon a fix does or does not show for the selected segment, and is not a
/// restatement of any one specific fix to the label-wrapping defect this
/// file exists to prove.
bool _isSelectedSegment(WidgetTester tester, String label) {
  final SemanticsNode node = tester.getSemantics(_segmentLabelFinder(label));
  final bool? isSelected = node.flagsCollection.isSelected.toBoolOrNull();
  expect(
    isSelected,
    isNotNull,
    reason:
        'fixture is broken: the "$label" segment\'s merged Semantics '
        'node does not carry an isSelected flag at all (Tristate.none); '
        'SegmentedButton always sets Semantics(selected: ...) explicitly '
        '(flutter/src/material/segmented_button.dart:634), so this means '
        'something upstream of this file changed',
  );
  return isSelected!;
}

/// Finds the single `RichText` painting the label of the segment carrying
/// [label], and returns the live `RenderParagraph` behind it.
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

/// How many lines dart:ui actually broke the label of the segment carrying
/// [label] into, at the width the segment laid it out at.
///
/// Copied technique from test/game_screen_token_label_fit_test.dart:296-348
/// (`RenderParagraph` exposes no line-count accessor of its own on this
/// SDK): every input that fed the real `RenderParagraph`'s layout is read
/// straight off that render object and replayed into a fresh `TextPainter`,
/// because that is the only way to ask dart:ui how many lines it actually
/// broke the on-screen paragraph into.
int _lineCountOfSegmentLabel(WidgetTester tester, String label) {
  final RenderParagraph paragraph = _paragraphOfSegmentLabel(tester, label);
  final TextPainter probe = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  try {
    return probe.computeLineMetrics().length;
  } finally {
    probe.dispose();
  }
}

/// The natural, unbounded single-line width of the label of the segment
/// carrying [label] -- the width it would occupy laid out with no width
/// limit at all, independent of the box the real segment happens to give
/// it right now. Same technique as `_lineCountOfSegmentLabel`, every input
/// read off the live `RenderParagraph`, except laid out under no
/// `maxWidth`. Reported for order 148's requirement 7 (the Arabic
/// selected-label tie-breaker): this is the same "natural width against
/// the box's own allowed width" pair order 146's worker reported headless
/// (51.7dp inside 60.91dp), now measured under the real render tree with
/// the real font loaded, rather than inferred.
double _naturalSegmentLabelWidth(WidgetTester tester, String label) {
  final RenderParagraph paragraph = _paragraphOfSegmentLabel(tester, label);
  final TextPainter probe = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout();
  try {
    return probe.width;
  } finally {
    probe.dispose();
  }
}

/// The localised label for [players], read off [loc] rather than typed as a
/// literal anywhere a test body can see it directly.
String _playersLabel(AppLocalizations loc, int players) {
  return switch (players) {
    2 => loc.homePlayersTwo,
    3 => loc.homePlayersThree,
    4 => loc.homePlayersFour,
    _ => throw ArgumentError.value(
      players,
      'players',
      'home_screen_players_fit_test.dart only knows the three player '
          'counts the selector offers (2, 3, 4)',
    ),
  };
}

void main() {
  setUpAll(_loadAppFonts);

  group('sanity: the real fonts loaded by setUpAll are actually in effect, '
      'not the flutter_test Ahem substitute (order 148 requirement 1)', () {
    testWidgets(
      'Poppins: two 10-character Latin strings of very different letter '
      'shapes measure different natural widths',
      (tester) async {
        const double fontSize = 48;
        const String narrow = 'iiiiiiiiii';
        const String wide = 'WWWWWWWWWW';
        const TextStyle style = TextStyle(
          fontFamily: 'Poppins',
          fontSize: fontSize,
        );

        final double narrowWidth = _naturalWidthOf(
          narrow,
          style,
          TextDirection.ltr,
        );
        final double wideWidth = _naturalWidthOf(
          wide,
          style,
          TextDirection.ltr,
        );
        final double ahemPredictedWidth = fontSize * narrow.length;

        // Proof for the record, not decoration: this is the real number
        // this run measured, quoted verbatim in this file's own run
        // report rather than assumed.
        // ignore: avoid_print
        print(
          'home_screen_players_fit_test sanity (Poppins, fontSize '
          '$fontSize): "$narrow" natural width = ${narrowWidth}dp, '
          '"$wide" natural width = ${wideWidth}dp; the Ahem-predicted '
          'width for any 10-character string at this size would be '
          'exactly ${ahemPredictedWidth}dp for both strings, since every '
          'Ahem glyph is an identical fixed square as wide as the font '
          'size regardless of which character it represents',
        );

        expect(
          (narrowWidth - wideWidth).abs(),
          greaterThan(1.0),
          reason:
              'the Poppins font does not appear to have actually loaded: '
              '"$narrow" and "$wide" are both 10 characters and measured '
              '${narrowWidth}dp and ${wideWidth}dp, within 1.0dp of each '
              'other. Under the real, proportional Poppins font these '
              'must differ substantially ("W" is far wider than "i" in '
              'any Latin proportional font); two same-length strings '
              'measuring equal is exactly what the Ahem substitute font '
              'would produce instead, since Ahem gives every glyph an '
              'identical fixed-width square regardless of content',
        );
        expect(
          narrowWidth,
          isNot(closeTo(ahemPredictedWidth, 1.0)),
          reason:
              'the Poppins font does not appear to have actually loaded: '
              '"$narrow" measured ${narrowWidth}dp, within 1.0dp of the '
              'Ahem-predicted ${ahemPredictedWidth}dp (fontSize '
              '$fontSize x ${narrow.length} characters) for a substitute '
              'font whose every glyph is a fixed square as wide as the '
              'font size',
        );
      },
    );

    testWidgets(
      'Noto Sans Arabic: two 5-character Arabic strings of very different '
      'letter shapes measure different natural widths',
      (tester) async {
        const double fontSize = 48;
        // 'ا' (alef) is a single narrow vertical stroke in Arabic script;
        // 'م' (meem) carries a bowl/loop and is visibly wider in any real
        // Arabic typeface. Both strings are exactly 5 characters.
        const String narrow =
            'اااا'
            'ا';
        const String wide =
            'ممم'
            'مم';
        const TextStyle style = TextStyle(
          fontFamily: 'Noto Sans Arabic',
          fontSize: fontSize,
        );

        final double narrowWidth = _naturalWidthOf(
          narrow,
          style,
          TextDirection.rtl,
        );
        final double wideWidth = _naturalWidthOf(
          wide,
          style,
          TextDirection.rtl,
        );
        final double ahemPredictedWidth = fontSize * narrow.length;

        // ignore: avoid_print
        print(
          'home_screen_players_fit_test sanity (Noto Sans Arabic, '
          'fontSize $fontSize): "$narrow" natural width = '
          '${narrowWidth}dp, "$wide" natural width = ${wideWidth}dp; the '
          'Ahem-predicted width for any 5-character string at this size '
          'would be exactly ${ahemPredictedWidth}dp for both strings',
        );

        expect(
          (narrowWidth - wideWidth).abs(),
          greaterThan(1.0),
          reason:
              'the Noto Sans Arabic font does not appear to have '
              'actually loaded: "$narrow" and "$wide" are both 5 '
              'characters and measured ${narrowWidth}dp and '
              '${wideWidth}dp, within 1.0dp of each other. Under the '
              'real, proportional Noto Sans Arabic font these must '
              'differ ("م" carries a bowl and is wider than the single '
              'stroke of "ا"); two same-length strings measuring equal '
              'is exactly what the Ahem substitute font would produce '
              'instead',
        );
        expect(
          narrowWidth,
          isNot(closeTo(ahemPredictedWidth, 1.0)),
          reason:
              'the Noto Sans Arabic font does not appear to have '
              'actually loaded: "$narrow" measured ${narrowWidth}dp, '
              'within 1.0dp of the Ahem-predicted '
              '${ahemPredictedWidth}dp (fontSize $fontSize x '
              '${narrow.length} characters)',
        );
      },
    );

    testWidgets(
      'the mounted selector resolves its segment labels to fontFamily '
      'Poppins with fontFamilyFallback containing Noto Sans Arabic, off '
      'the real theme (the check order 146\'s worker used, applied here)',
      (tester) async {
        _pinPhoneView(tester);
        await _mount(tester, const Locale('en'));
        final BuildContext context = tester.element(find.byType(Scaffold));
        final AppLocalizations loc = AppLocalizations.of(context);

        final RenderParagraph paragraph = _paragraphOfSegmentLabel(
          tester,
          _playersLabel(loc, 4),
        );
        final TextStyle? style = paragraph.text.style;
        expect(
          style,
          isNotNull,
          reason:
              'fixture is broken: the 4-players segment label\'s '
              'RenderParagraph carries a null style',
        );

        // ignore: avoid_print
        print(
          'home_screen_players_fit_test sanity (theme wiring): the '
          '4-players segment label\'s resolved TextStyle carries '
          'fontFamily=${style!.fontFamily}, '
          'fontFamilyFallback=${style.fontFamilyFallback}',
        );

        expect(
          style.fontFamily,
          'Poppins',
          reason:
              'expected the segment label\'s resolved TextStyle.fontFamily '
              'to be "Poppins" (lib/src/theme.dart kLudoFontFamily), got '
              '"${style.fontFamily}" -- this file is not mounted inside '
              'the app\'s real theme, or the theme changed which family it '
              'asks for',
        );
        expect(
          style.fontFamilyFallback,
          contains('Noto Sans Arabic'),
          reason:
              'expected the segment label\'s resolved '
              'TextStyle.fontFamilyFallback to contain "Noto Sans Arabic" '
              '(lib/src/theme.dart kLudoFontFallbacks), got '
              '${style.fontFamilyFallback}',
        );

        tester.view.reset();
      },
    );
  });

  group('the player-count selector renders every segment label on one line at '
      'phone width, for every selection state, under the real fonts and '
      'the real theme '
      '(work/ludo/orders/148-players-selector-fit-proof-real-fonts.md)', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      group('${locale.languageCode}:', () {
        for (final int selected in const <int>[2, 3, 4]) {
          group('with $selected players selected:', () {
            for (final int measured in const <int>[2, 3, 4]) {
              final String role = measured == selected
                  ? 'selected'
                  : 'unselected';
              testWidgets(
                'the $measured-players segment ($role) renders its label '
                'on exactly one line at the 1080x1848@2.75 phone geometry '
                'the overflow was photographed at',
                (tester) async {
                  final double logicalWidth = _pinPhoneView(tester);

                  await _mount(tester, locale);
                  final BuildContext context = tester.element(
                    find.byType(Scaffold),
                  );
                  final AppLocalizations loc = AppLocalizations.of(context);

                  final String selectedLabel = _playersLabel(loc, selected);
                  await _selectByTap(tester, selectedLabel);

                  // Rule 6 (order 147, kept): the segment under test must
                  // be distinguishable as selected or not, read off
                  // SegmentedButton's own Semantics(selected: ...), before
                  // the line-count assertion runs -- a fixture where the
                  // tap silently failed to move the selection must not be
                  // mistaken for a passing or failing line-count case
                  // below.
                  //
                  // The handle is disposed with an explicit try/finally
                  // right around its one use, not via addTearDown: on this
                  // Flutter SDK, flutter_test's own "was a SemanticsHandle
                  // left active" check
                  // (flutter_test/src/widget_tester.dart,
                  // WidgetTester._endOfTestVerifications) runs while the
                  // test body is still executing, before any addTearDown
                  // callback fires, so a handle only ever released via
                  // addTearDown reads as leaked on every case that reaches
                  // this point without throwing first (order 147's file
                  // confirmed this by running with addTearDown instead and
                  // recorded exactly which cases turned red because of it,
                  // not because of a real leak).
                  final String measuredLabel = _playersLabel(loc, measured);
                  final SemanticsHandle semanticsHandle = tester
                      .ensureSemantics();
                  final bool isSelected;
                  try {
                    isSelected = _isSelectedSegment(tester, measuredLabel);
                  } finally {
                    semanticsHandle.dispose();
                  }
                  expect(
                    isSelected,
                    measured == selected,
                    reason:
                        'home-players-selector (${locale.languageCode}): '
                        'after tapping "$selectedLabel", the '
                        '$measured-players segment\'s merged Semantics '
                        'node reports isSelected=$isSelected (expected '
                        '${measured == selected}); SegmentedButton sets '
                        'Semantics(selected: ...) directly off its own '
                        'selection set '
                        '(flutter/src/material/segmented_button.dart:'
                        '632-638), so this not matching means the tap did '
                        'not actually move the control\'s selection',
                  );

                  final int lines = _lineCountOfSegmentLabel(
                    tester,
                    measuredLabel,
                  );
                  final double naturalWidth = _naturalSegmentLabelWidth(
                    tester,
                    measuredLabel,
                  );
                  final RenderParagraph paragraph = _paragraphOfSegmentLabel(
                    tester,
                    measuredLabel,
                  );
                  final double boxMaxWidth = paragraph.constraints.maxWidth;

                  // Proof for the record, not decoration: this is the real
                  // per-(locale, selection state, measured segment) line
                  // count and width pair this run measured under the real
                  // fonts and the real theme, quoted verbatim in this
                  // file's own run report for order 148's requirement 6
                  // (the table) and requirement 7 (the Arabic tie-breaker),
                  // rather than assumed from order 146's headless numbers.
                  // ignore: avoid_print
                  print(
                    'home_screen_players_fit_test table row: locale='
                    '${locale.languageCode} selected=$selected '
                    'measured=$measured role=$role lines=$lines '
                    'naturalWidth=${naturalWidth}dp '
                    'boxMaxWidth=${boxMaxWidth}dp',
                  );

                  expect(
                    lines,
                    1,
                    reason:
                        'home-players-selector (${locale.languageCode}, '
                        '$selected players selected): the $role '
                        '$measured-players segment wrapped its label onto '
                        '$lines lines at a logical width of '
                        '${logicalWidth.toStringAsFixed(2)}dp (physical '
                        '${_devicePhysicalSize.width.toStringAsFixed(0)}x'
                        '${_devicePhysicalSize.height.toStringAsFixed(0)}, '
                        'dpr $_devicePixelRatio); measured under the real '
                        'Poppins/Noto Sans Arabic fonts and the real app '
                        'theme, the label\'s natural (unbounded) width is '
                        '${naturalWidth.toStringAsFixed(2)}dp against a '
                        'box of ${boxMaxWidth.toStringAsFixed(2)}dp; every '
                        'segment of the player-count selector must render '
                        'its label on a single line at a real phone '
                        'width, whichever segment is currently selected',
                  );

                  // Requirement 1 (order 147, kept): restore the view in
                  // the case body, not only in addTearDown. Reached only
                  // on the all-pass path; addTearDown(tester.view.reset)
                  // inside _pinPhoneView still covers every path that
                  // throws before here.
                  tester.view.reset();
                },
              );
            }
          });
        }
      });
    }
  });
}
