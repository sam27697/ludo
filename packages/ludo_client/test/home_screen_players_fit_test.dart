// A proof, independent of lib/src/home_screen.dart's own author, that every
// segment of the player-count selector on HomeScreen
// (work/ludo/orders/147-players-selector-fit-proof.md) lays its label out on
// a single line at a real phone width, in both languages this app ships, and
// for every selection a player can put the control in.
//
// The defect this guards against, recorded at
// work/ludo/evidence/146-home-en-4players-wrap.png (screenshots.yml run 13,
// 01-home-en.png): the selected segment's label "4 players" wraps across
// three lines, splitting the word after "player". Run 13's 02-home-ar.png
// wraps the selected Arabic segment too, across two lines, the digit on one
// line and the noun on the next -- the same check mark eating the same width
// -- even though work/ludo/STATE.md recorded that screenshot as rendering
// correctly for a full run; that record was taken at its word rather than by
// looking at the pixels, and was wrong. This file does not trust either
// language, or either selection state, to be fine by default: it measures
// every segment, in both locales, with each of the three segments selected
// in turn, and reports whatever the real render tree says, agreeing or not
// with any record written about it.
//
// This file's own measurement disagrees with one more claim in the order
// that commissioned it, and that disagreement is reported rather than
// smoothed over, the same as the Arabic correction above: the order's "why
// this order exists" section, going off the same screenshot, says the two
// *unselected* segments in 01-home-en.png "fit the same shape of label on
// one line at the same width". Measured here, off the real render tree at
// the same geometry, they do not, in the great majority of cases -- see this
// file's run report for the full per-segment table. The likely cause is not
// a defect this file can charge to home_screen.dart: `flutter_test` renders
// every widget test's text with the substitute "Ahem" font (documented at
// flutter_test's own matchers.dart: "By default, the Flutter framework uses
// a font called 'Ahem' which shows..."), which gives every character a
// fixed square glyph
// as wide as the font size, wider on average than the compact rounded
// custom font actually shipped and visible in the screenshot. No test in
// this package loads a real font (checked: nothing under test/ references
// FontLoader or loadAppFonts), including
// test/game_screen_token_label_fit_test.dart, whose own token buttons pass
// under the same substitute font only because their box is proportionally
// far wider relative to Ahem's inflated character width than this
// selector's ~61-91dp-wide segments are. This file does not attempt to load
// the real font or otherwise work around Ahem -- the order is explicit that
// the technique is to be copied, not extended -- so what it reports is
// exactly what `flutter_test`'s own default measurement technique says
// about the real, mounted render tree, stated plainly rather than trimmed
// to fit the order's own prediction of which cases would be red.
//
// No existing suite in this package can see any of this, because every
// existing assertion on this control is on the *string* a Text holds, at
// flutter_test's default 800x600 logical canvas, where the label fits on one
// line whatever it says and however wide the checkmark makes its segment.
// This file pins the view to the geometry the defect was photographed at and
// measures how the real RenderParagraph behind each segment's label actually
// broke its lines, not what string it holds or what a screenshot record
// claimed about it.
//
// Deliberately not asserted: the literal wording ("4 players", "لاعبين"). A
// fix for this defect is free to reword the label; a test that hardcoded the
// current string would fail the moment that happens, for a reason that has
// nothing to do with whether the label fits. Every label this file measures
// or taps is read back off AppLocalizations through the mounted tree's own
// BuildContext, never typed in here as a literal.
//
// Deliberately not asserted: the selected-segment checkmark icon, present or
// absent. Order 146 is fixing this defect the same night this file was
// written, blind to it, and the leading candidate fix removes that icon.
// What this file asserts instead, as the property that must survive whatever
// order 146 does: the segment under test carries
// `SemanticsFlag.isSelected` if and only if it is the one that was tapped
// (flutter/src/material/segmented_button.dart wraps every segment in
// `Semantics(selected: segmentSelected, ...)`, computed directly off the
// widget's own `selected` set, not off whether an icon happens to be
// present). That flag is part of SegmentedButton itself, not of
// home_screen.dart's body, so asserting it does not pin one particular fix
// the way asserting the icon's presence would.
//
// Deliberately not asserted: a RenderFlex "overflowed" exception. The label
// wraps inside its box and never spills past it, so no such exception is
// ever thrown here, on fixed or unfixed code, and a test watching for one
// would pass on the broken build.
//
// The line-count technique below -- read every input that fed the real
// RenderParagraph's layout (resolved InlineSpan, TextDirection, TextScaler,
// maxLines, locale, strutStyle, textWidthBasis, and the exact maxWidth
// constraint) straight off that render object, feed all of it into a fresh
// TextPainter, and call that TextPainter's own computeLineMetrics().length
// -- is copied from test/game_screen_token_label_fit_test.dart:296-348
// (RenderParagraph exposes no line-metrics accessor of its own on this SDK),
// per this order's explicit instruction: copy the technique, do not import
// from or extend that file, since it belongs to nobody this round and its
// private helpers would collide with this one.
//
// The phone geometry pinned below (1080x1848 physical, device pixel ratio
// 2.75) is the same constant pair test/game_screen_token_label_fit_test.dart
// carries and the same emulator geometry screenshots.yml runs at.
//
// One test case per (locale, selection state, measured segment) triple,
// eighteen in total, rather than one case per selection state that loops
// over all three segments: given how broadly this control wraps under the
// measurement technique above (see this file's run report), a looping case
// would abort at its first failing segment and never report the other two
// segments' real line counts at all. Eighteen independent cases mean every
// cell of the per-segment/per-locale/per-selection-state table this order
// asks for is a real, verbatim, individually reproducible test result, not
// an inference from whichever assertion happened to run first.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';

// The phone geometry the defect was photographed at (screenshots.yml run 13,
// 01-home-en.png / 02-home-ar.png), the same pair
// test/game_screen_token_label_fit_test.dart:108-109 carries.
const Size _devicePhysicalSize = Size(1080, 1848);
const double _devicePixelRatio = 2.75;

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

Widget _harness(Locale locale) {
  return MaterialApp(
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
/// [label], and returns how many lines dart:ui actually broke that label
/// into at the width the segment laid it out at.
///
/// Copied technique from test/game_screen_token_label_fit_test.dart:296-348
/// (see the file header for why it is copied rather than imported): every
/// input that fed the real `RenderParagraph`'s layout is read straight off
/// that render object and replayed into a fresh `TextPainter`, because
/// `RenderParagraph` itself exposes no line-count accessor on this SDK.
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
  group('the player-count selector renders every segment label on one line at '
      'phone width, for every selection state '
      '(work/ludo/orders/147-players-selector-fit-proof.md)', () {
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

                  // Rule 6: the segment under test must be distinguishable
                  // as selected or not, read off SegmentedButton's own
                  // Semantics(selected: ...), before the line-count
                  // assertion runs -- a fixture where the tap silently
                  // failed to move the selection must not be mistaken for
                  // a passing or failing line-count case below.
                  //
                  // The handle is disposed with an explicit try/finally
                  // right around its one use, not via addTearDown: on this
                  // Flutter SDK, flutter_test's own "was a SemanticsHandle
                  // left active" check
                  // (flutter_test/src/widget_tester.dart:1063-1074,
                  // WidgetTester._endOfTestVerifications) runs while the
                  // test body is still executing, before any addTearDown
                  // callback fires, so a handle only ever released via
                  // addTearDown reads as leaked on every case that reaches
                  // this point without throwing first -- confirmed by
                  // running this file with addTearDown(handle.dispose)
                  // instead, which failed exactly the two cases (ar, 3
                  // players selected, measuring the 2-players segment; ar,
                  // 4 players selected, measuring the 2-players segment)
                  // whose line-count assertion below does not itself fail.
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
                        'dpr $_devicePixelRatio); every segment of the '
                        'player-count selector must render its label on '
                        'a single line at a real phone width, whichever '
                        'segment is currently selected',
                  );

                  // Requirement 1: restore the view in the case body, not
                  // only in addTearDown. Reached only on the all-pass
                  // path; addTearDown(tester.view.reset) inside
                  // _pinPhoneView still covers every path that throws
                  // before here.
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
