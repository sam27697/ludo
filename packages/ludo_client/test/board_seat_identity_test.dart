// Acceptance tests for work/ludo/orders/C-248-seat-identity.md, written from
// that contract's text alone. Order 248 (lib/src/board.dart, lib/src/
// die_mark.dart) is being built in parallel by a different worker; this file
// was not written against its content, and LudoBoard.seatNames, .youLabel,
// .turnSeat and SeatPipStrip.seats, .turnSeat do not exist on this branch's
// base commit (integrate/run69 6846914). Every test below is expected to
// fail to compile there, by the master's own design for this order's
// acceptance step 1.
//
// Mounting copies test/board_test.dart's bare-LudoBoard harness and test/
// board_safe_squares_test.dart's MaterialApp-with-localization-delegates and
// pinned-viewport-plus-RepaintBoundary pixel-sampling technique -- copied,
// not imported, per this order's instruction. Every testWidgets body pumps
// one subject (standing lesson 35), with two narrow, precedented exceptions
// that each drive a second pumpWidget on the *same* subject to observe a
// transition rather than to compare two unrelated fixtures (the same idiom
// test/deep_link_test.dart's "even across a rebuild" case already uses):
//   - the muted-yards test (bullet 6) pumps the 4-seat board, samples, then
//     pumps the 2-seat board and samples again, because the contract's own
//     method for that bullet is "sampling ... and comparing with a 4-seat
//     board" -- a relative claim that cannot be checked against one render
//     without inventing an unstated "normal opacity" magic number;
//   - the turn-glow disposal test (bullet 5) pumps the board with
//     turnSeat set, then pumps a different, unrelated root to force
//     disposal, because the bullet itself is "no ticker left running after
//     the widget is removed".
//
// The quadrant a seat's yard sits in (bullet 3's "the 6x6 corner, from
// board_geometry.dart") is derived here from board_geometry.dart's own
// cellFor(seat, progress: -1, tokenIndex: 0), bucketed into the low or high
// half of the 15-wide grid -- not read off board.dart's private
// `yardCorners` local, which this file never sees. This is also the guard
// against the order's own example mutation ("the chip is placed by
// yardCorners of seat 0 for every seat"): a board that mis-wires every
// chip to seat 0's corner is caught the moment seat 2's chip is checked
// against seat 2's own, independently-derived quadrant.
//
// The "contrasting ink" rule (ruling 1: LudoColors.actionOn or
// LudoColors.ink, whichever has the higher contrast against the seat
// colour) is graded here by the
// standard WCAG relative-luminance contrast-ratio formula, computed at test
// time from LudoColors.seats itself, never from a hardcoded pick per seat --
// so a seat palette edit cannot silently make this test vacuous.
//
// Ambiguities found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   1. Ruling 2 allows "board-seat-you" to be "a descendant of
//      board-seat-name-0 (or adjacent to it inside seat 0's yard rect)".
//      Tested here as either: a tree descendant of the seat-0 chip, or
//      (if not) a widget whose rect's centre falls inside seat 0's own
//      yard quadrant. Whichever order 248 picks, one of the two branches
//      holds; neither is treated as the only correct reading.
//   2. Bullet 5's device sizes (360x800, 390x844) read as full device
//      viewports, not board widget sizes: the board is mounted filling a
//      bare Scaffold body with no outer SizedBox, and sizes itself through
//      its own internal LayoutBuilder exactly as it would inside a real
//      screen. The on-screen board rect is read from the Stack it builds
//      (a descendant of the `ludo-board` key), not from that key's own
//      rect, because LayoutBuilder's render box fills the constraints it is
//      given even when its child is smaller (see performLayout in the
//      Flutter SDK's layout_builder.dart) -- the `ludo-board` key's own
//      rect is the full viewport on a non-square screen, not the square
//      board.
//   3. Ruling 5's "key game-seat-pip-turn" is tested as its own, separately
//      findable key, compared by size against "game-seat-pip-0" -- exactly
//      the two keys the bullet names -- without assuming whether it nests
//      around the existing per-seat pip or replaces it, since ruling 7
//      ("every existing key ... is kept") is not explicit either way.
//
// Order 267, contract C-264 part A amendment (run 73, base a9b3350):
//
//   A1 amends the Geometry group's own hit-rect non-overlap assertion (the
//   loop over board-token-hit-0-<index> inside runGeometryCase, "seat 0's
//   name chip ... must not overlap its own yard token hit target"). C-264's
//   own words are "the chip may overlap a yard token's hit rect; it must
//   not overlap a yard token's drawn disc" -- a strictly weaker claim than
//   the old one (a hit rect is never smaller than its disc at these
//   viewports: board.dart's own _tokenHitRect and the token's drawn
//   Positioned share one centre, and _tokenHitSize's 48dp floor is never
//   under the drawn tokenSize = cellSize * 0.7 for any board this file
//   mounts). So amending this assertion alone cannot newly fail by itself
//   on a9b3350; see the A1 case's own comment for the measured verdict.
//   The drawn disc's rect is read from the existing `token-<seat>-<index>`
//   key -- not recomputed from a second copy of board.dart's hit-rect
//   formula, and not board_geometry.dart's cellFor plus a hand-rebuilt fan
//   offset either. That key already exists on this base (bullet 6 above
//   already finds it, to check a muted seat draws no token at all) and is
//   the Semantics node board.dart wraps directly around the painted
//   circle's DecoratedBox, positioned by the same Positioned(left:
//   drawnLeft, top: drawnTop, width: tokenSize, height: tokenSize) that is
//   the drawn disc -- reading it this way means a defect in the chip's own
//   placement math can never be hidden by this check happening to reuse
//   the same (possibly also wrong) formula.
//
//   A2 is new: two cases (en, ar) at a 340 logical px wide board, seat 0
//   (top edge row) and seat 2 (bottom edge row) -- A2's own text names both
//   rows ("the top row for the top yards, the bottom row for the bottom
//   ones") -- asserting the rendered board-seat-name-<s> chip (not the
//   wider Positioned box that merely bounds where it may sit) is at least
//   85% of a cell tall, and that its name Text's resolved font size is at
//   least 10 logical px. `_fixedHarness` grew an optional `boardSide`
//   parameter (default 400, so every existing call is unaffected) rather
//   than a second, near-duplicate harness function.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/theme.dart';

// ---------------------------------------------------------------------------
// Shared fixtures and geometry/colour helpers.
// ---------------------------------------------------------------------------

/// All four seats, each with four tokens sitting in their own yard
/// (progress -1). The default fixture for every case that does not care
/// about token position.
Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in <int>[0, 1, 2, 3]) seat: <int>[-1, -1, -1, -1],
};

/// Mounts [LudoBoard] under a MaterialApp with the app's own localization
/// delegates (test/board_safe_squares_test.dart's harness, copied), inside a
/// fixed-size box, for cases that only need keys, text and widget presence
/// and do not depend on the board's on-screen pixel geometry.
Widget _fixedHarness({
  required Map<int, List<int>> tokens,
  List<int> seatsInPlay = const <int>[0, 1, 2, 3],
  int? mySeat,
  Map<int, String>? seatNames,
  String? youLabel,
  int? turnSeat,
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
  double boardSide = 400,
}) {
  final Widget board = LudoBoard(
    tokens: tokens,
    seatsInPlay: seatsInPlay,
    mySeat: mySeat,
    seatNames: seatNames,
    youLabel: youLabel,
    turnSeat: turnSeat,
  );
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: boardSide,
          height: boardSide,
          child: disableAnimations
              ? Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: board,
                  ),
                )
              : board,
        ),
      ),
    ),
  );
}

/// Mounts [LudoBoard] filling a bare Scaffold body -- no outer SizedBox --
/// so the board sizes itself from whatever viewport [tester] is pinned to,
/// the way a real screen would hand it space. Used by bullet 3 (Geometry),
/// which names device viewport sizes, not board sizes.
Widget _screenHarness({
  required Map<int, List<int>> tokens,
  List<int> seatsInPlay = const <int>[0, 1, 2, 3],
  int? mySeat,
  Map<int, String>? seatNames,
  String? youLabel,
  int? turnSeat,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: LudoBoard(
        tokens: tokens,
        seatsInPlay: seatsInPlay,
        mySeat: mySeat,
        seatNames: seatNames,
        youLabel: youLabel,
        turnSeat: turnSeat,
      ),
    ),
  );
}

/// Mounts [LudoBoard] wrapped in a [RepaintBoundary] with no outer SizedBox
/// scaling surprises, for the pixel-sampling muted-yard check. Pin the
/// viewport to [_pixelBoardSide] square with [_pinViewportToBoard] first so
/// this fills exactly that square, the same technique test/
/// board_safe_squares_test.dart uses for its start-square colour check.
Widget _pixelHarness({
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: RepaintBoundary(
        child: LudoBoard(tokens: tokens, seatsInPlay: seatsInPlay),
      ),
    ),
  );
}

const double _pixelBoardSide = 450;

void _pinViewportToBoard(WidgetTester tester) {
  tester.view.physicalSize = const Size(_pixelBoardSide, _pixelBoardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Samples the colour at board-local point [local] (0,0 at the board's own
/// top-left) by rendering the single [RepaintBoundary] in the tree to an
/// image and reading its raw RGBA bytes -- the exact method test/
/// board_safe_squares_test.dart already uses for the start-square colour
/// check, named here per this order's "name the method in the test".
Future<Color> _samplePixel(WidgetTester tester, Offset local) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  ui.Image? renderedImage;
  ByteData? pixels;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    renderedImage = image;
    pixels = data;
  });
  final ui.Image image = renderedImage!;
  final ByteData rgba = pixels!;
  final double scale = image.width / _pixelBoardSide;
  final int x = (local.dx * scale).round().clamp(0, image.width - 1);
  final int y = (local.dy * scale).round().clamp(0, image.height - 1);
  final int i = (y * image.width + x) * 4;
  return Color.fromARGB(
    rgba.getUint8(i + 3),
    rgba.getUint8(i),
    rgba.getUint8(i + 1),
    rgba.getUint8(i + 2),
  );
}

/// The on-screen rect of the board's own square content, read from the
/// Stack LudoBoard builds (a descendant of the `ludo-board` key) rather
/// than that key's own rect -- see ambiguity 2 above for why those differ
/// on a non-square viewport.
Rect _boardRect(WidgetTester tester) {
  final Finder stack = find.descendant(
    of: find.byKey(const Key('ludo-board')),
    matching: find.byType(Stack),
  );
  return tester.getRect(stack);
}

/// Which 6x6 corner (in board cell coordinates) holds [seat]'s yard, read
/// from board_geometry.dart's own cellFor rather than any board.dart
/// private constant: tokenIndex 0's yard cell falls in exactly one of the
/// four 6x6 corners (board_geometry.dart's own layout comment), so
/// bucketing its (col, row) into the low or high half of the 15-wide grid
/// gives the quadrant without hand-coding a seat-to-corner table.
({int colLow, int rowLow}) _yardQuadrantOrigin(int seat) {
  final BoardCell cell = cellFor(seat: seat, progress: -1, tokenIndex: 0);
  return (colLow: cell.col <= 5 ? 0 : 9, rowLow: cell.row <= 5 ? 0 : 9);
}

/// [seat]'s 6x6 yard quadrant, in the same screen coordinates [tester]
/// reports for any other widget rect.
Rect _yardQuadrantRect(WidgetTester tester, int seat) {
  final Rect board = _boardRect(tester);
  final double cellSize = board.width / 15;
  final ({int colLow, int rowLow}) origin = _yardQuadrantOrigin(seat);
  return Rect.fromLTWH(
    board.left + origin.colLow * cellSize,
    board.top + origin.rowLow * cellSize,
    6 * cellSize,
    6 * cellSize,
  );
}

/// True when every corner of [inner] lies inside [outer], within
/// [epsilon] logical pixels of slack for subpixel layout rounding --
/// the same 0.5px tolerance test/board_safe_squares_test.dart's own
/// rect-edge assertions use.
bool _rectInside(Rect outer, Rect inner, [double epsilon = 0.5]) {
  return inner.left >= outer.left - epsilon &&
      inner.top >= outer.top - epsilon &&
      inner.right <= outer.right + epsilon &&
      inner.bottom <= outer.bottom + epsilon;
}

/// WCAG relative luminance of [c] (sRGB, linearised), for the contrast-ratio
/// formula below. [Color.r]/[.g]/[.b] are already 0..1 components.
double _srgbToLinear(double channel) {
  if (channel <= 0.03928) {
    return channel / 12.92;
  }
  return math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color c) =>
    0.2126 * _srgbToLinear(c.r) +
    0.7152 * _srgbToLinear(c.g) +
    0.0722 * _srgbToLinear(c.b);

/// WCAG contrast ratio between two colours: (L1 + 0.05) / (L2 + 0.05) with
/// L1 the lighter of the two, per
/// https://www.w3.org/TR/UNDERSTANDING-WCAG20/visual-audio-contrast-contrast.html.
double _contrastRatio(Color a, Color b) {
  final double la = _relativeLuminance(a);
  final double lb = _relativeLuminance(b);
  final double lighter = math.max(la, lb);
  final double darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Ruling 1's rule, computed rather than hand-picked per seat: the light
/// ink if it contrasts more strongly against [seatColor] than
/// [LudoColors.ink] does, otherwise ink. The light ink is the paintbox's
/// near-white [LudoColors.actionOn], not a new literal white (C-248 rule 1
/// as amended in run 71).
Color _expectedChipInk(Color seatColor) {
  final double light = _contrastRatio(LudoColors.actionOn, seatColor);
  final double ink = _contrastRatio(LudoColors.ink, seatColor);
  return light >= ink ? LudoColors.actionOn : LudoColors.ink;
}

/// The effective text colour of the [Text] widget carrying [data]: its own
/// style if it sets one, otherwise whatever ambient [DefaultTextStyle] it
/// inherits -- covering both "Text(name, style: TextStyle(color: ...))"
/// and "DefaultTextStyle(style: ..., child: Text(name))" implementations.
Color? _effectiveTextColor(WidgetTester tester, Finder textFinder) {
  final Text text = tester.widget<Text>(textFinder);
  if (text.style?.color != null) {
    return text.style!.color;
  }
  final Element element = tester.element(textFinder);
  return DefaultTextStyle.of(element).style.color;
}

const String _fortyCharName = 'ZxcvbnmqweZxcvbnmqweZxcvbnmqweZxcvbnmqwe';

void main() {
  test('fixture sanity: the long-name fixture is exactly 40 characters', () {
    expect(
      _fortyCharName.length,
      40,
      reason:
          'bullet 4 names a 40-character name explicitly; the fixture '
          'string must actually be 40 characters or the test below is not '
          'testing what it claims to',
    );
  });

  // ===========================================================================
  // Bullet 1 -- Defaults.
  // ===========================================================================
  group('Defaults (bullet 1)', () {
    // Kills: a chip, tag or glow drawn even though seatNames/youLabel/
    // turnSeat were never given -- the contract's own "defaults reproduce
    // today's drawing exactly" (the ruling that introduces these three
    // parameters).
    testWidgets('a LudoBoard built with only tokens and seatsInPlay has no '
        'board-seat-name-*, board-seat-you or board-turn-yard-* for any seat', (
      tester,
    ) async {
      await tester.pumpWidget(_fixedHarness(tokens: _allInYard()));
      await tester.pump();

      for (final int seat in <int>[0, 1, 2, 3]) {
        expect(
          find.byKey(Key('board-seat-name-$seat')),
          findsNothing,
          reason:
              'seat $seat: board-seat-name-$seat must not exist when '
              'seatNames was never passed (seed: seat=$seat)',
        );
        expect(
          find.byKey(Key('board-turn-yard-$seat')),
          findsNothing,
          reason:
              'seat $seat: board-turn-yard-$seat must not exist when '
              'turnSeat was never passed (seed: seat=$seat)',
        );
      }
      expect(find.byKey(const Key('board-seat-you')), findsNothing);
      expect(find.byKey(const Key('board-my-yard')), findsNothing);
    });

    // Kills: the you-ring or you-tag gated on mySeat alone, skipping
    // ruling 2's explicit "and seatNames is non-null" condition -- the
    // mirror image of the case above, with the pre-existing mySeat
    // parameter now set.
    testWidgets(
      'mySeat set but seatNames left null: still no board-seat-you and no '
      'board-my-yard',
      (tester) async {
        await tester.pumpWidget(_fixedHarness(tokens: _allInYard(), mySeat: 0));
        await tester.pump();

        expect(
          find.byKey(const Key('board-seat-you')),
          findsNothing,
          reason:
              'mySeat alone, without seatNames, must not be enough to draw '
              'the you-tag (ruling 2: "when mySeat is non-null and in play '
              'and seatNames is non-null")',
        );
        expect(
          find.byKey(const Key('board-my-yard')),
          findsNothing,
          reason:
              'mySeat alone, without seatNames, must not be enough to draw '
              'the my-yard ring either',
        );
      },
    );

    // Kills: SeatPipStrip drawing fewer than four pips by default, or a
    // turn-pip key appearing with no turnSeat given.
    testWidgets(
      'SeatPipStrip() with neither seats nor turnSeat draws all four pips '
      'and no turn pip',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SeatPipStrip())),
        );
        await tester.pump();

        for (final int seat in <int>[0, 1, 2, 3]) {
          expect(
            find.byKey(Key('game-seat-pip-$seat')),
            findsOneWidget,
            reason:
                'default SeatPipStrip must draw pip $seat (seed: seat=$seat)',
          );
        }
        expect(find.byKey(const Key('game-seat-pip-turn')), findsNothing);
      },
    );
  });

  // ===========================================================================
  // Bullet 2 -- Names.
  // ===========================================================================
  group('Names (bullet 2)', () {
    // Kills: a chip missing for a named in-play seat, a chip appearing for
    // an un-named or out-of-play seat, the you-tag duplicated or attached
    // to the wrong seat, the my-yard ring missing, and a contrasting-ink
    // rule that is hardcoded to one colour regardless of the seat's own
    // colour (seat 0 is red, where white must win; seat 2 is yellow, where
    // ink must win -- see the computed picks in the header comment's
    // worked contrast ratios).
    testWidgets(
      'seatsInPlay [0, 2], seatNames {0: Sam, 2: Lina}, mySeat 0: each '
      'chip shows its name in the higher-contrast ink, no chip for 1 or 3, '
      'exactly one board-seat-you tied to seat 0, and board-my-yard found',
      (tester) async {
        await tester.pumpWidget(
          _fixedHarness(
            tokens: _allInYard(),
            seatsInPlay: const <int>[0, 2],
            seatNames: const <int, String>{0: 'Sam', 2: 'Lina'},
            mySeat: 0,
            youLabel: 'You',
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('board-seat-name-0')), findsOneWidget);
        expect(find.byKey(const Key('board-seat-name-2')), findsOneWidget);
        expect(
          find.byKey(const Key('board-seat-name-1')),
          findsNothing,
          reason: 'seat 1 has no seatNames entry and is not in play either',
        );
        expect(
          find.byKey(const Key('board-seat-name-3')),
          findsNothing,
          reason: 'seat 3 has no seatNames entry and is not in play either',
        );

        final Finder samText = find.descendant(
          of: find.byKey(const Key('board-seat-name-0')),
          matching: find.text('Sam'),
        );
        expect(
          samText,
          findsOneWidget,
          reason: 'board-seat-name-0 must show the literal text "Sam"',
        );
        final Finder linaText = find.descendant(
          of: find.byKey(const Key('board-seat-name-2')),
          matching: find.text('Lina'),
        );
        expect(
          linaText,
          findsOneWidget,
          reason: 'board-seat-name-2 must show the literal text "Lina"',
        );

        final Color expectedSeat0Ink = _expectedChipInk(LudoColors.seats[0]);
        expect(
          _effectiveTextColor(tester, samText),
          expectedSeat0Ink,
          reason:
              'seat 0 is red (${LudoColors.seats[0]}); the higher-contrast '
              'ink against it is $expectedSeat0Ink, computed by WCAG '
              'contrast ratio, not hardcoded',
        );
        final Color expectedSeat2Ink = _expectedChipInk(LudoColors.seats[2]);
        expect(
          _effectiveTextColor(tester, linaText),
          expectedSeat2Ink,
          reason:
              'seat 2 is yellow (${LudoColors.seats[2]}); the '
              'higher-contrast ink against it is $expectedSeat2Ink -- '
              'different from seat 0\'s pick, so a hardcoded single colour '
              'for every chip cannot pass both assertions',
        );

        final Finder youFinder = find.byKey(const Key('board-seat-you'));
        expect(
          youFinder,
          findsOneWidget,
          reason:
              'exactly one board-seat-you must exist: mySeat 0 is in play '
              'and has a seatNames entry',
        );
        final Finder nestedInSeat0 = find.descendant(
          of: find.byKey(const Key('board-seat-name-0')),
          matching: youFinder,
        );
        final bool isDescendantOfSeat0Chip = nestedInSeat0
            .evaluate()
            .isNotEmpty;
        if (!isDescendantOfSeat0Chip) {
          final Rect youRect = tester.getRect(youFinder);
          final Rect seat0Yard = _yardQuadrantRect(tester, 0);
          expect(
            seat0Yard.contains(youRect.center),
            isTrue,
            reason:
                'board-seat-you is neither a descendant of '
                'board-seat-name-0 nor inside seat 0\'s own yard quadrant '
                '$seat0Yard (its rect is $youRect) -- ruling 2 allows '
                'either, not neither',
          );
        }

        expect(
          find.byKey(const Key('board-my-yard')),
          findsOneWidget,
          reason:
              'mySeat 0 is in play with a seatNames entry: the my-yard '
              'ring must be drawn',
        );
      },
    );

    // Kills: a chip rendered straight from the seatNames map without
    // checking seatsInPlay membership first -- ruling 1's own gate is
    // "every seat in seatsInPlay that has an entry", in that order.
    testWidgets(
      'a seatNames entry for a seat not in seatsInPlay draws no chip for '
      'that seat',
      (tester) async {
        await tester.pumpWidget(
          _fixedHarness(
            tokens: _allInYard(),
            seatsInPlay: const <int>[0, 2],
            seatNames: const <int, String>{0: 'Sam', 1: 'Ghost'},
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('board-seat-name-0')), findsOneWidget);
        expect(
          find.byKey(const Key('board-seat-name-1')),
          findsNothing,
          reason:
              'seat 1 has a seatNames entry ("Ghost") but is not in '
              'seatsInPlay [0, 2]; it must still get no chip',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 3 -- Geometry.
  // ===========================================================================
  group('Geometry (bullet 3)', () {
    // Kills: a chip placed by the wrong seat's quadrant (the order's own
    // named example, "the chip is placed by yardCorners of seat 0 for
    // every seat" -- caught the moment seat 2's chip is checked against
    // seat 2's own quadrant), and a chip that overlaps its own seat's
    // 48dp token hit target.
    Future<void> runGeometryCase(WidgetTester tester, Size viewport) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final Map<int, List<int>> tokens = _allInYard();
      await tester.pumpWidget(
        _screenHarness(
          tokens: tokens,
          seatsInPlay: const <int>[0, 2],
          seatNames: const <int, String>{0: 'Sam', 2: 'Lina'},
          mySeat: 0,
        ),
      );
      await tester.pump();

      for (final int seat in <int>[0, 2]) {
        final Rect chip = tester.getRect(
          find.byKey(Key('board-seat-name-$seat')),
        );
        final Rect quadrant = _yardQuadrantRect(tester, seat);
        expect(
          _rectInside(quadrant, chip),
          isTrue,
          reason:
              'at viewport $viewport: seat $seat\'s chip rect $chip must '
              'lie inside its own yard quadrant $quadrant (seed: '
              'seat=$seat, viewport=$viewport); a chip placed by another '
              'seat\'s quadrant fails here',
        );
      }

      // Amended for contract C-264 rule A1 (order 267): this used to read
      //   final Rect seat0Chip = tester.getRect(
      //     find.byKey(const Key('board-seat-name-0')),
      //   );
      //   for (var index = 0; index < 4; index++) {
      //     final Finder hit = find.byKey(Key('board-token-hit-0-$index'));
      //     if (hit.evaluate().isEmpty) {
      //       continue;
      //     }
      //     final Rect hitRect = tester.getRect(hit);
      //     expect(
      //       seat0Chip.overlaps(hitRect),
      //       isFalse,
      //       reason:
      //           'at viewport $viewport: seat 0\'s name chip $seat0Chip must '
      //           'not overlap its own yard token hit target '
      //           'board-token-hit-0-$index at $hitRect (seed: index=$index, '
      //           'viewport=$viewport)',
      //     );
      //   }
      // C-264 rule A1 permits that overlap now ("the chip may overlap a
      // yard token's hit rect") and forbids a narrower thing instead ("it
      // must not overlap a yard token's drawn disc"), so the check below
      // reads token-0-<index> (the drawn disc, board.dart's own Semantics
      // node wrapping the painted circle, positioned by the same left/top/
      // tokenSize math the circle is drawn with) rather than
      // board-token-hit-0-<index> (the hit rect).
      final Rect seat0Chip = tester.getRect(
        find.byKey(const Key('board-seat-name-0')),
      );
      for (var index = 0; index < 4; index++) {
        final Finder disc = find.byKey(Key('token-0-$index'));
        if (disc.evaluate().isEmpty) {
          continue;
        }
        final Rect discRect = tester.getRect(disc);
        expect(
          seat0Chip.overlaps(discRect),
          isFalse,
          reason:
              'at viewport $viewport: seat 0\'s name chip $seat0Chip must '
              'not overlap its own yard token\'s drawn disc token-0-$index '
              'at $discRect (contract C-264 rule A1) (seed: index=$index, '
              'viewport=$viewport)',
        );
      }
    }

    testWidgets('at 360 x 800', (tester) async {
      await runGeometryCase(tester, const Size(360, 800));
    });

    testWidgets('at 390 x 844', (tester) async {
      await runGeometryCase(tester, const Size(390, 844));
    });
  });

  // ===========================================================================
  // C-264 rule A2 (order 267) -- the chip is tall enough and its text never
  // drops below the 10px floor, at a 340 logical px wide board.
  // ===========================================================================
  group('Chip height and text floor at a 340px board (A2)', () {
    // Checks both of A2's own rows (seat 0, the top edge row; seat 2, the
    // bottom edge row) in the same case, same fixture (seatsInPlay [0, 2],
    // seatNames {0: Sam, 2: Lina}) the Geometry group above already uses, in
    // each of the two named locales.
    //
    // Kills: a chip clamped down to whatever room is left once a yard
    // token's hit box is avoided (today's bug, the sliver chips the
    // contract's "Seen" section names), and a font-size floor left at the
    // old 7px rather than raised to A2's 10px.
    Future<void> runA2Case(WidgetTester tester, Locale locale) async {
      await tester.pumpWidget(
        _fixedHarness(
          tokens: _allInYard(),
          seatsInPlay: const <int>[0, 2],
          seatNames: const <int, String>{0: 'Sam', 2: 'Lina'},
          boardSide: 340,
          locale: locale,
        ),
      );
      await tester.pump();

      final double cellSize = _boardRect(tester).width / 15;
      const Map<int, String> namesBySeat = <int, String>{0: 'Sam', 2: 'Lina'};

      for (final MapEntry<int, String> entry in namesBySeat.entries) {
        final int seat = entry.key;
        final String name = entry.value;

        final Finder chip = find.byKey(Key('board-seat-name-$seat'));
        expect(
          chip,
          findsOneWidget,
          reason:
              'fixture: seat $seat must have a name chip (locale '
              '${locale.languageCode}, seed: seat=$seat)',
        );
        final double chipHeight = tester.getRect(chip).height;
        expect(
          chipHeight,
          greaterThanOrEqualTo(cellSize * 0.85),
          reason:
              'A2: seat $seat\'s chip height ($chipHeight) must be at '
              'least 85% of a cell ($cellSize) at a 340px board, locale '
              '${locale.languageCode} (seed: seat=$seat, cellSize=$cellSize)',
        );

        final Finder nameText = find.descendant(
          of: chip,
          matching: find.text(name),
        );
        expect(
          nameText,
          findsOneWidget,
          reason:
              'fixture: seat $seat\'s chip must show the literal text '
              '"$name" (locale ${locale.languageCode}, seed: seat=$seat)',
        );
        final double? fontSize = tester.widget<Text>(nameText).style?.fontSize;
        expect(
          fontSize,
          isNotNull,
          reason:
              'A2: seat $seat\'s name Text must set an explicit font size '
              'to check against the 10px floor (locale '
              '${locale.languageCode}, seed: seat=$seat)',
        );
        expect(
          fontSize!,
          greaterThanOrEqualTo(10.0),
          reason:
              'A2: seat $seat\'s name Text font size ($fontSize) must not '
              'drop below 10 logical px at a 340px board, locale '
              '${locale.languageCode} (seed: seat=$seat)',
        );
      }
    }

    testWidgets('en', (tester) async {
      await runA2Case(tester, const Locale('en'));
    });

    testWidgets('ar', (tester) async {
      await runA2Case(tester, const Locale('ar'));
    });
  });

  // ===========================================================================
  // Bullet 4 -- a long name is ellipsized, not an overflow.
  // ===========================================================================
  group('Long name (bullet 4)', () {
    // Kills: a chip that grows to fit a long name instead of ellipsizing,
    // spilling outside the yard or throwing a RenderFlex overflow error.
    testWidgets('a 40-character name stays inside the yard quadrant, is marked '
        'single-line and ellipsized, and throws no overflow error', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _screenHarness(
          tokens: _allInYard(),
          seatsInPlay: const <int>[0, 2],
          seatNames: const <int, String>{0: _fortyCharName},
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'mounting a 40-character name must not throw a render '
            'overflow error',
      );

      final Finder chip = find.byKey(const Key('board-seat-name-0'));
      expect(chip, findsOneWidget);
      final Rect chipRect = tester.getRect(chip);
      final Rect quadrant = _yardQuadrantRect(tester, 0);
      expect(
        _rectInside(quadrant, chipRect),
        isTrue,
        reason:
            'the chip for a 40-character name, rect $chipRect, must '
            'still lie inside seat 0\'s yard quadrant $quadrant rather '
            'than growing past it',
      );

      final Finder nameText = find.descendant(
        of: chip,
        matching: find.text(_fortyCharName),
      );
      expect(
        nameText,
        findsOneWidget,
        reason:
            'the full 40-character string must still be the Text data '
            '(ellipsis is rendering, not truncation of the data itself)',
      );
      final Text text = tester.widget<Text>(nameText);
      expect(
        text.maxLines,
        1,
        reason: 'bullet 1: "one line" -- maxLines must be 1',
      );
      expect(
        text.overflow,
        TextOverflow.ellipsis,
        reason:
            'bullet 1: "ellipsized" -- overflow must be '
            'TextOverflow.ellipsis',
      );
    });
  });

  // ===========================================================================
  // Bullet 5 -- whose turn.
  // ===========================================================================
  group('Turn (bullet 5)', () {
    // Kills: the glow key attached to the wrong seat, or more than one
    // glow key present at once.
    testWidgets(
      'turnSeat 2: board-turn-yard-2 is found and no other seat carries '
      'board-turn-yard-*',
      (tester) async {
        await tester.pumpWidget(
          _fixedHarness(
            tokens: _allInYard(),
            seatsInPlay: const <int>[0, 1, 2, 3],
            turnSeat: 2,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('board-turn-yard-2')), findsOneWidget);
        for (final int seat in <int>[0, 1, 3]) {
          expect(
            find.byKey(Key('board-turn-yard-$seat')),
            findsNothing,
            reason:
                'turnSeat is 2; board-turn-yard-$seat must not exist for '
                'seat $seat (seed: seat=$seat)',
          );
        }
      },
    );

    // Kills: a glow drawn even though turnSeat was never given.
    testWidgets('turnSeat null: no board-turn-yard-* for any seat', (
      tester,
    ) async {
      await tester.pumpWidget(_fixedHarness(tokens: _allInYard()));
      await tester.pump();

      for (final int seat in <int>[0, 1, 2, 3]) {
        expect(
          find.byKey(Key('board-turn-yard-$seat')),
          findsNothing,
          reason:
              'turnSeat is null; board-turn-yard-$seat must not exist '
              '(seed: seat=$seat)',
        );
      }
    });

    // Kills: reduced motion removing the glow entirely instead of freezing
    // it (doctrine P9: "remove animations shortens motion, it does not
    // remove meaning").
    testWidgets(
      'turnSeat 2 under MediaQuery.disableAnimations: board-turn-yard-2 is '
      'still found',
      (tester) async {
        await tester.pumpWidget(
          _fixedHarness(
            tokens: _allInYard(),
            turnSeat: 2,
            disableAnimations: true,
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('board-turn-yard-2')),
          findsOneWidget,
          reason:
              'reduced motion must keep the turn glow\'s meaning (it is '
              'still turnSeat 2\'s turn), only its motion may go',
        );
      },
    );

    // Kills: a pulse ticker that is never cancelled when the board is
    // disposed -- this test never calls pumpAndSettle against it (the
    // glow "repeats", per this order's own warning) and instead removes
    // the board with a second, unrelated pumpWidget and reads
    // tester.binding.hasScheduledFrame directly, the literal check this
    // bullet names.
    testWidgets(
      'turnSeat 2, then the board is removed from the tree: no frame is '
      'left scheduled after a bounded settle',
      (tester) async {
        await tester.pumpWidget(
          _fixedHarness(tokens: _allInYard(), turnSeat: 2),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('board-turn-yard-2')), findsOneWidget);

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(
          tester.binding.hasScheduledFrame,
          isFalse,
          reason:
              'the turn glow\'s ticker must stop when the board is '
              'disposed; a leftover ticker keeps a frame scheduled here '
              'even with the board gone from the tree',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 6 -- muted yards for seats not in play.
  // ===========================================================================
  group('Muted yards (bullet 6)', () {
    // Kills: a yard drawn at the same opacity whether its seat is in play
    // or not -- today's bug this ruling exists to fix, and ruling 4's own
    // words that this is "the one default change" (no seatNames,
    // youLabel or turnSeat involved at all). Compares against a live
    // 4-seat render rather than a hardcoded "normal opacity" number; see
    // the file header's note on why this one case drives two pumps.
    testWidgets('seatsInPlay [0, 2]: seat 1\'s and seat 3\'s yard centre reads '
        'lighter (closer to background) than the same point on a 4-seat '
        'board where they are in play', (tester) async {
      _pinViewportToBoard(tester);
      final Map<int, List<int>> tokens = _allInYard();
      final double cellSize = _pixelBoardSide / 15;

      Offset yardCentre(int seat) {
        final ({int colLow, int rowLow}) origin = _yardQuadrantOrigin(seat);
        return Offset(
          (origin.colLow + 3) * cellSize,
          (origin.rowLow + 3) * cellSize,
        );
      }

      await tester.pumpWidget(
        _pixelHarness(tokens: tokens, seatsInPlay: const <int>[0, 1, 2, 3]),
      );
      await tester.pump();
      final Color seat1InPlay = await _samplePixel(tester, yardCentre(1));
      final Color seat3InPlay = await _samplePixel(tester, yardCentre(3));

      await tester.pumpWidget(
        _pixelHarness(tokens: tokens, seatsInPlay: const <int>[0, 2]),
      );
      await tester.pump();
      final Color seat1Muted = await _samplePixel(tester, yardCentre(1));
      final Color seat3Muted = await _samplePixel(tester, yardCentre(3));

      expect(
        find.byKey(const Key('token-1-0')),
        findsNothing,
        reason:
            'seat 1 is not in play in the muted render; it must have '
            'no token widgets',
      );
      expect(
        find.byKey(const Key('token-3-0')),
        findsNothing,
        reason:
            'seat 3 is not in play in the muted render; it must have '
            'no token widgets',
      );

      expect(
        _relativeLuminance(seat1Muted) > _relativeLuminance(seat1InPlay),
        isTrue,
        reason:
            'seat 1 yard centre: muted sample $seat1Muted '
            '(luminance ${_relativeLuminance(seat1Muted).toStringAsFixed(4)}) '
            'must read lighter than the in-play sample $seat1InPlay '
            '(luminance ${_relativeLuminance(seat1InPlay).toStringAsFixed(4)}) '
            'at the same point on a 4-seat board (seed: seat=1)',
      );
      expect(
        _relativeLuminance(seat3Muted) > _relativeLuminance(seat3InPlay),
        isTrue,
        reason:
            'seat 3 yard centre: muted sample $seat3Muted '
            '(luminance ${_relativeLuminance(seat3Muted).toStringAsFixed(4)}) '
            'must read lighter than the in-play sample $seat3InPlay '
            '(luminance ${_relativeLuminance(seat3InPlay).toStringAsFixed(4)}) '
            'at the same point on a 4-seat board (seed: seat=3)',
      );
    });
  });

  // ===========================================================================
  // Bullet 7 -- the seat-pip strip.
  // ===========================================================================
  group('Pip strip (bullet 7)', () {
    // Kills: the strip ignoring `seats` and drawing all four regardless,
    // or drawing the given seats out of ascending order.
    testWidgets(
      'seats [0, 2]: only pips 0 and 2 are drawn, pip 0 left of pip 2',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: SeatPipStrip(seats: <int>[0, 2])),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('game-seat-pip-0')), findsOneWidget);
        expect(find.byKey(const Key('game-seat-pip-2')), findsOneWidget);
        expect(find.byKey(const Key('game-seat-pip-1')), findsNothing);
        expect(find.byKey(const Key('game-seat-pip-3')), findsNothing);

        final double pip0Dx = tester
            .getTopLeft(find.byKey(const Key('game-seat-pip-0')))
            .dx;
        final double pip2Dx = tester
            .getTopLeft(find.byKey(const Key('game-seat-pip-2')))
            .dx;
        expect(
          pip0Dx < pip2Dx,
          isTrue,
          reason:
              'pip 0 (x=$pip0Dx) must be drawn left of pip 2 (x=$pip2Dx), '
              'ascending seat order under LTR',
        );
      },
    );

    // Kills: the turn pip key missing, more than one turn pip present, or
    // the turn pip drawn the same size as an ordinary pip.
    testWidgets(
      'seats [0, 2], turnSeat 2: game-seat-pip-turn is found exactly once '
      'and is larger than pip 0',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: SeatPipStrip(seats: <int>[0, 2], turnSeat: 2)),
          ),
        );
        await tester.pump();

        final Finder turnPip = find.byKey(const Key('game-seat-pip-turn'));
        expect(turnPip, findsOneWidget);

        final Size turnSize = tester.getSize(turnPip);
        final Size pip0Size = tester.getSize(
          find.byKey(const Key('game-seat-pip-0')),
        );
        expect(
          turnSize.width > pip0Size.width && turnSize.height > pip0Size.height,
          isTrue,
          reason:
              'game-seat-pip-turn ($turnSize) must be larger than an '
              'ordinary pip ($pip0Size)',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 8 -- Arabic.
  // ===========================================================================
  group('Arabic (bullet 8)', () {
    // Kills: the chip's text forced to a fixed LTR direction regardless of
    // the ambient app locale, and the you-tag not carrying the literal
    // Arabic string it was given (not routed through a not-yet-wired
    // AppLocalizations member -- rule 6 of the contract is explicit that
    // no .arb change is part of this contract).
    testWidgets(
      'Locale(ar), an Arabic name and youLabel: the chip text direction is '
      'RTL and the tag reads the given Arabic string',
      (tester) async {
        const String arabicName = 'سامر';
        const String arabicYou = 'أنت';

        await tester.pumpWidget(
          _fixedHarness(
            tokens: _allInYard(),
            seatsInPlay: const <int>[0, 2],
            seatNames: const <int, String>{0: arabicName},
            mySeat: 0,
            youLabel: arabicYou,
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();

        final Finder nameText = find.descendant(
          of: find.byKey(const Key('board-seat-name-0')),
          matching: find.text(arabicName),
        );
        expect(
          nameText,
          findsOneWidget,
          reason: 'the chip must show the literal Arabic name it was given',
        );
        final Element nameElement = tester.element(nameText);
        expect(
          Directionality.of(nameElement),
          TextDirection.rtl,
          reason:
              'bullet 8: the chip\'s text direction must follow the app '
              'directionality, which is RTL under Locale(ar)',
        );

        final Finder youFinder = find.byKey(const Key('board-seat-you'));
        expect(youFinder, findsOneWidget);
        final Finder youText = find.descendant(
          of: youFinder,
          matching: find.text(arabicYou),
        );
        final bool tagIsYouWidgetItself =
            tester
                .widgetList(youFinder)
                .whereType<Text>()
                .any((Text t) => t.data == arabicYou) &&
            youText.evaluate().isEmpty;
        expect(
          youText.evaluate().isNotEmpty || tagIsYouWidgetItself,
          isTrue,
          reason:
              'bullet 8: the you-tag must read the literal youLabel '
              'string "$arabicYou" it was given, not an English fallback',
        );

        // Ruling 6: "the board is not mirrored in Arabic (yards keep their
        // corners)". Seat 0's chip must still be in seat 0's own top-left
        // quadrant, not mirrored to the top-right.
        final Rect chipRect = tester.getRect(
          find.byKey(const Key('board-seat-name-0')),
        );
        final Rect seat0Quadrant = _yardQuadrantRect(tester, 0);
        expect(
          _rectInside(seat0Quadrant, chipRect),
          isTrue,
          reason:
              'ruling 6: the board itself is not mirrored under Arabic; '
              'seat 0\'s chip at $chipRect must still sit inside seat 0\'s '
              'own (unmirrored) yard quadrant $seat0Quadrant',
        );
      },
    );
  });
}
