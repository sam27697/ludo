// Holds LudoBoard to work/ludo/orders/600-absent-arms-shared-marks.md (C-600),
// written from that contract's text alone. Order 600 (lib/src/board.dart) is
// built in parallel by a different worker; this file was not written against
// its content.
//
// D1, the arms of a seat that is not in play: pixel checks. The board is
// rendered through a RepaintBoundary (test/board_seat_identity_test.dart's
// muted-yard approach, bullet 6, and test/board_safe_squares_test.dart's
// start-square check) and each cell's centre-of-interest is sampled. Expected
// colours are computed from LudoColors and the contract's alphas, never
// pasted from a sample.
//
// D2, the mark on a shared disc: widget checks. The disc diameter is read
// from the rendered `token-<seat>-<index>` box (the layout's own answer), the
// SeatMark under it is read for its size, and whether it paints is read from
// the presence of a CustomPaint under the SeatMark.
//
// Ambiguities reported rather than invented around:
//   1. Contract case (a) says the entry square of a seat equals "the board
//      background blended with LudoColors.seats[s] at the muted alpha". The
//      entry square sits on the plain track fill (paperElevated at 0.65 over
//      the background), and D1 says the paint order does not change, so the
//      expected colour here blends the seat colour over that track fill. The
//      literal reading (seat colour straight over the background) would be
//      a different colour for muted and full strength alike, and the
//      existing test/board_safe_squares_test.dart start-square check already
//      pins the track fill under a full-strength entry square.
//   2. Contract case (a) says the "centre pixel" of the entry square. The
//      safe-square star is drawn at the centre of that cell, so the sample
//      is taken 3 px in from the cell's top-left corner, the point
//      test/board_safe_squares_test.dart already uses for the same cell.
//      Home column cells are sampled at their centre.
//   3. Case (d), the star on an absent seat's entry square, is checked by the
//      presence and rect of the board-safe-<n> keys (all eight, none lost
//      to muting), not by star pixels; the contract does not give the star's
//      colour or shape.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart';

// The contract's numbers, written out once. The factor is the one the yard
// already uses for a seat not in play.
const double _mutedFactor = 0.35;
const double _homeAlpha = 0.45;
const double _entryAlpha = 0.85;
const double _trackAlpha = 0.65;

// Mark fractions of the drawn disc: D2's new one for a shared slot, and the
// one-seat fan's, unchanged.
const double _sharedMarkFraction = 0.62;
const double _fanMarkFraction = 0.5;

// Disc diameters as fractions of a cell: the layout's own three.
const double _fanDisc = 0.7;
const double _sharedDisc = 0.5;
const double _crowdedDisc = 0.36;

// SeatMark draws nothing below this (lib/src/seat_mark.dart, rule 4).
const double _markFloor = 6;

// ---------------------------------------------------------------------------
// Pixel harness (D1).
// ---------------------------------------------------------------------------

const double _pixelSide = 450;
const double _pixelCell = _pixelSide / 15;
const Key _captureKey = Key('c600-capture');

void _pinViewportToBoard(WidgetTester tester) {
  tester.view.physicalSize = const Size(_pixelSide, _pixelSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<int, List<int>> _yardsOf(List<int> seats) => <int, List<int>>{
  for (final int seat in seats) seat: <int>[-1, -1, -1, -1],
};

Widget _pixelHarness({required List<int> seatsInPlay, int? mySeat}) {
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
        key: _captureKey,
        child: LudoBoard(
          tokens: _yardsOf(seatsInPlay),
          seatsInPlay: seatsInPlay,
          mySeat: mySeat,
        ),
      ),
    ),
  );
}

/// Renders the capture boundary once and returns a sampler over board-local
/// points, as 8-bit channels (alpha ignored; the board is opaque).
Future<List<int> Function(Offset)> _renderSampler(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_captureKey),
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
  if (rgba.lengthInBytes < image.width * image.height * 4) {
    fail(
      'rendering the board produced ${rgba.lengthInBytes} bytes, too few '
      'for a ${image.width}x${image.height} RGBA image',
    );
  }
  final double scale = image.width / _pixelSide;
  return (Offset local) {
    final int x = (local.dx * scale).round().clamp(0, image.width - 1);
    final int y = (local.dy * scale).round().clamp(0, image.height - 1);
    final int i = (y * image.width + x) * 4;
    return <int>[rgba.getUint8(i), rgba.getUint8(i + 1), rgba.getUint8(i + 2)];
  };
}

List<int> _channels(Color c) => <int>[
  (c.r * 255).round(),
  (c.g * 255).round(),
  (c.b * 255).round(),
];

/// The plain main-track fill under any non-entry track cell, and under an
/// entry square before its own colour goes on.
Color get _trackFill => Color.alphaBlend(
  LudoColors.paperElevated.withValues(alpha: _trackAlpha),
  LudoColors.dieFace,
);

Color _expectedHome(int seat, {required bool muted}) => Color.alphaBlend(
  LudoColors.seats[seat].withValues(
    alpha: muted ? _homeAlpha * _mutedFactor : _homeAlpha,
  ),
  LudoColors.paperElevated,
);

Color _expectedEntry(int seat, {required bool muted}) => Color.alphaBlend(
  LudoColors.seats[seat].withValues(
    alpha: muted ? _entryAlpha * _mutedFactor : _entryAlpha,
  ),
  _trackFill,
);

bool _differs(List<int> a, List<int> b, int tolerance) {
  for (int i = 0; i < 3; i++) {
    if ((a[i] - b[i]).abs() > tolerance) {
      return true;
    }
  }
  return false;
}

/// Samples every home column cell (progress 52 to 56) and every entry square
/// of all four seats and returns one line per cell that is not within
/// [tolerance] of the colour the contract gives it. An empty list is a pass.
Future<List<String>> _armMismatches(
  WidgetTester tester, {
  required List<int> seatsInPlay,
  int? mySeat,
  int tolerance = 3,
}) async {
  final List<int> Function(Offset) sample = await _renderSampler(tester);
  final int quarters = viewQuarters(mySeat);
  final List<String> bad = <String>[];

  for (int seat = 0; seat < 4; seat++) {
    final bool muted = !seatsInPlay.contains(seat);

    for (int progress = 52; progress <= 56; progress++) {
      final BoardCell cell = toView(
        cellFor(seat: seat, progress: progress),
        quarters,
      );
      final List<int> got = sample(
        Offset((cell.col + 0.5) * _pixelCell, (cell.row + 0.5) * _pixelCell),
      );
      final List<int> want = _channels(_expectedHome(seat, muted: muted));
      if (_differs(got, want, tolerance)) {
        bad.add(
          'seat $seat home column progress $progress (view cell '
          '${cell.col},${cell.row}, ${muted ? "absent" : "in play"}): '
          'rgb $got, expected rgb $want within $tolerance',
        );
      }
    }

    final BoardCell entry = toView(cellFor(seat: seat, progress: 0), quarters);
    final List<int> got = sample(
      Offset(entry.col * _pixelCell + 3, entry.row * _pixelCell + 3),
    );
    final List<int> want = _channels(_expectedEntry(seat, muted: muted));
    if (_differs(got, want, tolerance)) {
      bad.add(
        'seat $seat entry square (view cell ${entry.col},${entry.row}, '
        '${muted ? "absent" : "in play"}): rgb $got, expected rgb $want '
        'within $tolerance',
      );
    }
  }
  return bad;
}

void _expectArms(List<String> bad, String scenario) {
  expect(
    bad,
    isEmpty,
    reason:
        'scenario: $scenario. Arm cells off the contract colour '
        '(D1: absent seat home column at alpha $_homeAlpha * $_mutedFactor, '
        'entry square at $_entryAlpha * $_mutedFactor; seats in play at '
        '$_homeAlpha and $_entryAlpha):\n${bad.join("\n")}',
  );
}

// ---------------------------------------------------------------------------
// Token harness (D2).
// ---------------------------------------------------------------------------

Widget _boardHarness({
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  double side = 344,
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
      body: Center(
        child: SizedBox(
          width: side,
          height: side,
          child: LudoBoard(tokens: tokens, seatsInPlay: seatsInPlay),
        ),
      ),
    ),
  );
}

/// The progress seat [seat] has when standing on absolute main-track square
/// [absolute] (docs/RULES.md 1.2: entry squares 0, 13, 26, 39).
int _progressAt(int seat, int absolute) => (absolute - 13 * seat) % 52;

/// Every token of every seat in [seatsInPlay] in the yard, then [placed]
/// (seat -> token index -> progress) laid over it.
Map<int, List<int>> _tokensWith(
  List<int> seatsInPlay,
  Map<int, Map<int, int>> placed,
) {
  final Map<int, List<int>> tokens = _yardsOf(seatsInPlay);
  placed.forEach((int seat, Map<int, int> byIndex) {
    byIndex.forEach((int index, int progress) {
      tokens[seat]![index] = progress;
    });
  });
  return tokens;
}

typedef _Slot = (int seat, int index);

/// Asserts, for token [seat]/[index], that its disc is [discFraction] of a
/// cell across, that it carries exactly one SeatMark of its own seat at
/// [markFraction] of the disc, and that the mark paints (a CustomPaint under
/// it) exactly when it is at least 6 dp.
void _expectMark(
  WidgetTester tester, {
  required int seat,
  required int index,
  required double side,
  required double discFraction,
  required double markFraction,
  required String scenario,
}) {
  final String who = 'token-$seat-$index';
  final String seed =
      'scenario: $scenario (seat=$seat, token=$index, board=$side)';
  final double cell = side / 15;
  final Finder token = find.byKey(Key(who));
  expect(token, findsOneWidget, reason: '$who is not on the board; $seed');

  final double disc = tester.getSize(token).width;
  expect(
    disc,
    closeTo(discFraction * cell, 0.01),
    reason:
        '$who disc is $disc dp; the scenario expects '
        '${discFraction * cell} dp (${discFraction}x of a $cell dp cell), '
        'so the layout this case exercises is not the one intended; $seed',
  );

  final Finder markFinder = find.descendant(
    of: token,
    matching: find.byType(SeatMark),
  );
  expect(
    markFinder,
    findsOneWidget,
    reason: '$who must carry exactly one SeatMark; $seed',
  );
  final SeatMark mark = tester.widget<SeatMark>(markFinder);
  expect(
    mark.seat,
    seat,
    reason: '$who SeatMark is for seat ${mark.seat}; $seed',
  );

  final double expectedMark = markFraction * disc;
  expect(
    mark.size,
    closeTo(expectedMark, 1e-6),
    reason:
        '$who SeatMark size is ${mark.size}; expected $markFraction x disc '
        '$disc = $expectedMark (D2); $seed',
  );
  expect(
    tester.getSize(markFinder).width,
    closeTo(expectedMark, 0.01),
    reason:
        '$who SeatMark renders ${tester.getSize(markFinder).width} dp wide; '
        'expected $expectedMark; $seed',
  );

  final Finder painted = find.descendant(
    of: markFinder,
    matching: find.byType(CustomPaint),
  );
  if (expectedMark >= _markFloor) {
    expect(
      painted,
      findsOneWidget,
      reason:
          '$who mark of $expectedMark dp is at least $_markFloor, so it must '
          'paint (a CustomPaint under SeatMark); got the empty fallback; '
          '$seed',
    );
  } else {
    expect(
      painted,
      findsNothing,
      reason:
          '$who mark of $expectedMark dp is under $_markFloor, so SeatMark '
          'must render its empty fallback (the accepted residue of D2); '
          '$seed',
    );
  }
}

void _expectAll(
  WidgetTester tester,
  List<_Slot> slots, {
  required double side,
  required double discFraction,
  required double markFraction,
  required String scenario,
}) {
  for (final _Slot slot in slots) {
    _expectMark(
      tester,
      seat: slot.$1,
      index: slot.$2,
      side: side,
      discFraction: discFraction,
      markFraction: markFraction,
      scenario: scenario,
    );
  }
}

void main() {
  // =========================================================================
  // D1 -- the arms of a seat not in play.
  // =========================================================================
  group('D1: arms of seats not in play are muted (cases a, b, c)', () {
    final List<(String, List<int>, int?)> scenarios =
        <(String, List<int>, int?)>[
          ('(a) two seats 0 and 2: seats 1 and 3 muted', <int>[0, 2], null),
          ('(a) two seats 1 and 3: seats 0 and 2 muted', <int>[1, 3], null),
          (
            '(a) two adjacent seats 0 and 1: seats 2 and 3 muted',
            <int>[0, 1],
            null,
          ),
          ('(b) three seats 0, 1, 2: seat 3 muted', <int>[0, 1, 2], null),
          ('(b) three seats 0, 1, 3: seat 2 muted', <int>[0, 1, 3], null),
          ('(b) three seats 1, 2, 3: seat 0 muted', <int>[1, 2, 3], null),
          ('(c) four seats: nothing muted', <int>[0, 1, 2, 3], null),
          (
            'two seats 0 and 2 on a board turned for seat 2: the muted arms '
                'follow the rotation',
            <int>[0, 2],
            2,
          ),
          ('two seats 1 and 3 on a board turned for seat 1', <int>[1, 3], 1),
          (
            'three seats 0, 1, 2 on a board turned for seat 1',
            <int>[0, 1, 2],
            1,
          ),
          ('four seats on a board turned for seat 3', <int>[0, 1, 2, 3], 3),
        ];

    for (final (String, List<int>, int?) s in scenarios) {
      testWidgets(s.$1, (WidgetTester tester) async {
        _pinViewportToBoard(tester);
        await tester.pumpWidget(_pixelHarness(seatsInPlay: s.$2, mySeat: s.$3));
        await tester.pump();

        final List<String> bad = await _armMismatches(
          tester,
          seatsInPlay: s.$2,
          mySeat: s.$3,
        );
        _expectArms(bad, '${s.$1}; seatsInPlay=${s.$2}, mySeat=${s.$3}');
      });
    }

    testWidgets('a seat that leaves (four seats, then seats 0 and 2 only): '
        'the arms repaint muted', (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      await tester.pumpWidget(
        _pixelHarness(seatsInPlay: const <int>[0, 1, 2, 3]),
      );
      await tester.pump();
      _expectArms(
        await _armMismatches(tester, seatsInPlay: const <int>[0, 1, 2, 3]),
        'four seats before the change; seatsInPlay=[0, 1, 2, 3]',
      );

      await tester.pumpWidget(_pixelHarness(seatsInPlay: const <int>[0, 2]));
      await tester.pump();
      _expectArms(
        await _armMismatches(tester, seatsInPlay: const <int>[0, 2]),
        'after seats 1 and 3 left; seatsInPlay=[0, 2] (the painter must '
        'repaint when the seat list changes)',
      );
    });

    test('the contract colours are distinguishable: muted differs from full '
        'for every seat, so the pixel cases above cannot pass vacuously', () {
      for (int seat = 0; seat < 4; seat++) {
        expect(
          _differs(
            _channels(_expectedHome(seat, muted: true)),
            _channels(_expectedHome(seat, muted: false)),
            3,
          ),
          isTrue,
          reason:
              'seat $seat home column: muted and full colours are within 3 '
              'per channel of each other, the tolerance would hide the rule',
        );
        expect(
          _differs(
            _channels(_expectedEntry(seat, muted: true)),
            _channels(_expectedEntry(seat, muted: false)),
            3,
          ),
          isTrue,
          reason:
              'seat $seat entry square: muted and full colours are within 3 '
              'per channel of each other, the tolerance would hide the rule',
        );
      }
    });
  });

  // =========================================================================
  // D1 -- the safe-square stars stay (case d).
  // =========================================================================
  group('D1: the stars on absent seats\' entry squares are still drawn '
      '(case d)', () {
    const List<int> safe = <int>[0, 8, 13, 21, 26, 34, 39, 47];

    for (final List<int> seats in <List<int>>[
      <int>[0, 2],
      <int>[1, 3],
      <int>[2, 3],
    ]) {
      testWidgets('seatsInPlay $seats: all eight board-safe-<n> stars are '
          'present, each on its square', (WidgetTester tester) async {
        _pinViewportToBoard(tester);
        await tester.pumpWidget(_pixelHarness(seatsInPlay: seats));
        await tester.pump();

        for (final int n in safe) {
          final Finder star = find.byKey(Key('board-safe-$n'));
          expect(
            star,
            findsOneWidget,
            reason:
                'board-safe-$n must be drawn whoever sits (the rules do not '
                'depend on it); seatsInPlay=$seats, n=$n',
          );
          final Rect got = tester.getRect(star);
          final BoardCell cell = safeSquareCell(n);
          expect(
            got.center.dx,
            closeTo((cell.col + 0.5) * _pixelCell, 0.5),
            reason:
                'board-safe-$n centre x; seatsInPlay=$seats, n=$n, '
                'cell=$cell',
          );
          expect(
            got.center.dy,
            closeTo((cell.row + 0.5) * _pixelCell, 0.5),
            reason:
                'board-safe-$n centre y; seatsInPlay=$seats, n=$n, '
                'cell=$cell',
          );
        }
      });
    }
  });

  // =========================================================================
  // D2 -- the mark on a shared disc (cases e and g).
  // =========================================================================
  group('D2: a token in a shared slot draws its mark at 0.62 of the disc '
      '(case e)', () {
    // Each scenario: name, board side, the tokens placed (seat -> index ->
    // absolute square), the seats in play.
    final List<(String, double, List<_Slot>, int, List<int>)> cases =
        <(String, double, List<_Slot>, int, List<int>)>[
          (
            'three seats on safe square 8, 344 board',
            344,
            <_Slot>[(0, 0), (1, 0), (2, 0)],
            8,
            <int>[0, 1, 2],
          ),
          (
            'three seats on entry square 0, 344 board',
            344,
            <_Slot>[(0, 0), (1, 0), (3, 0)],
            0,
            <int>[0, 1, 3],
          ),
          (
            'three seats on plain square 5, 344 board',
            344,
            <_Slot>[(1, 0), (2, 0), (3, 0)],
            5,
            <int>[1, 2, 3],
          ),
          (
            'two seats on square 13 (the smallest sharing), 344 board',
            344,
            <_Slot>[(0, 0), (2, 0)],
            13,
            <int>[0, 2],
          ),
          (
            'four seats, one token each, on square 26 (four occupants, the '
                'largest 0.5 disc), 344 board',
            344,
            <_Slot>[(0, 0), (1, 0), (2, 0), (3, 0)],
            26,
            <int>[0, 1, 2, 3],
          ),
          (
            'two seats with two tokens each (four occupants), 344 board',
            344,
            <_Slot>[(0, 0), (0, 1), (3, 0), (3, 1)],
            21,
            <int>[0, 3],
          ),
          (
            'three seats on square 8, 450 board',
            450,
            <_Slot>[(0, 0), (1, 0), (2, 0)],
            8,
            <int>[0, 1, 2],
          ),
          (
            'three seats on square 8, 280 board (mark 0.31 of a cell is '
                'under 6, so it falls back)',
            280,
            <_Slot>[(0, 0), (1, 0), (2, 0)],
            8,
            <int>[0, 1, 2],
          ),
        ];

    for (final (String, double, List<_Slot>, int, List<int>) c in cases) {
      testWidgets(c.$1, (WidgetTester tester) async {
        final Map<int, Map<int, int>> placed = <int, Map<int, int>>{};
        for (final _Slot slot in c.$3) {
          placed.putIfAbsent(slot.$1, () => <int, int>{})[slot.$2] =
              _progressAt(slot.$1, c.$4);
        }
        await tester.pumpWidget(
          _boardHarness(
            tokens: _tokensWith(c.$5, placed),
            seatsInPlay: c.$5,
            side: c.$2,
          ),
        );
        await tester.pump();

        _expectAll(
          tester,
          c.$3,
          side: c.$2,
          discFraction: _sharedDisc,
          markFraction: _sharedMarkFraction,
          scenario: '${c.$1}; absolute=${c.$4}, seatsInPlay=${c.$5}',
        );
      });
    }

    testWidgets('three seats on one square at 344: each disc carries a mark '
        'of at least 6 dp that paints (the point of D2)', (
      WidgetTester tester,
    ) async {
      const List<int> seats = <int>[0, 1, 2];
      await tester.pumpWidget(
        _boardHarness(
          tokens: _tokensWith(seats, <int, Map<int, int>>{
            0: <int, int>{0: _progressAt(0, 8)},
            1: <int, int>{0: _progressAt(1, 8)},
            2: <int, int>{0: _progressAt(2, 8)},
          }),
          seatsInPlay: seats,
        ),
      );
      await tester.pump();

      for (final int seat in seats) {
        final Finder token = find.byKey(Key('token-$seat-0'));
        final double disc = tester.getSize(token).width;
        final Finder mark = find.descendant(
          of: token,
          matching: find.byType(SeatMark),
        );
        final double size = tester.getSize(mark).width;
        expect(
          size,
          greaterThanOrEqualTo(_markFloor),
          reason:
              'token-$seat-0 on a shared safe square of a 344 dp board has a '
              'disc of $disc dp and a mark of $size dp; P9 needs the mark '
              'to reach $_markFloor dp (scenario: three seats on square 8, '
              'seat=$seat)',
        );
        expect(
          find.descendant(of: mark, matching: find.byType(CustomPaint)),
          findsOneWidget,
          reason:
              'token-$seat-0 mark of $size dp must paint a shape, not the '
              'empty SizedBox (scenario: three seats on square 8, '
              'seat=$seat)',
        );
      }
    });
  });

  group('D2: five or more occupants (0.36 discs) take 0.62 too, and stay '
      'under the floor at 344 dp (case g)', () {
    const List<_Slot> five = <_Slot>[(0, 0), (0, 1), (1, 0), (1, 1), (2, 0)];

    Map<int, List<int>> fiveTokens() => _tokensWith(
      const <int>[0, 1, 2],
      <int, Map<int, int>>{
        0: <int, int>{0: _progressAt(0, 8), 1: _progressAt(0, 8)},
        1: <int, int>{0: _progressAt(1, 8), 1: _progressAt(1, 8)},
        2: <int, int>{0: _progressAt(2, 8)},
      },
    );

    testWidgets('five occupants on square 8, 344 board: mark 0.62 of the '
        '0.36 disc, under 6 dp, fallback rendered', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _boardHarness(tokens: fiveTokens(), seatsInPlay: const <int>[0, 1, 2]),
      );
      await tester.pump();

      _expectAll(
        tester,
        five,
        side: 344,
        discFraction: _crowdedDisc,
        markFraction: _sharedMarkFraction,
        scenario: 'five occupants (seat 0 x2, seat 1 x2, seat 2 x1) on 8',
      );
      final double disc = tester
          .getSize(find.byKey(const Key('token-2-0')))
          .width;
      expect(
        _sharedMarkFraction * disc,
        lessThan(_markFloor),
        reason:
            'the accepted residue: a 0.36 disc at 344 dp is $disc dp and its '
            'mark ${_sharedMarkFraction * disc} dp, under $_markFloor; if '
            'this is no longer so, D2\'s stated residue changed',
      );
    });

    testWidgets('five occupants on square 8, 450 board: the same fraction, '
        'and now at least 6 dp so it paints', (WidgetTester tester) async {
      await tester.pumpWidget(
        _boardHarness(
          tokens: fiveTokens(),
          seatsInPlay: const <int>[0, 1, 2],
          side: 450,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        five,
        side: 450,
        discFraction: _crowdedDisc,
        markFraction: _sharedMarkFraction,
        scenario: 'five occupants on 8, 450 board',
      );
      final double mark =
          tester.getSize(find.byKey(const Key('token-2-0'))).width *
          _sharedMarkFraction;
      expect(
        mark,
        greaterThanOrEqualTo(_markFloor),
        reason: 'scenario check: a 450 board must lift the mark to the floor',
      );
    });

    testWidgets('sixteen tokens (all seats, all tokens) on entry square 0, '
        '344 board: every disc 0.36, every mark 0.62', (
      WidgetTester tester,
    ) async {
      const List<int> seats = <int>[0, 1, 2, 3];
      final Map<int, Map<int, int>> placed = <int, Map<int, int>>{
        for (final int seat in seats)
          seat: <int, int>{for (int i = 0; i < 4; i++) i: _progressAt(seat, 0)},
      };
      await tester.pumpWidget(
        _boardHarness(tokens: _tokensWith(seats, placed), seatsInPlay: seats),
      );
      await tester.pump();

      _expectAll(
        tester,
        <_Slot>[
          for (final int seat in seats)
            for (int i = 0; i < 4; i++) (seat, i),
        ],
        side: 344,
        discFraction: _crowdedDisc,
        markFraction: _sharedMarkFraction,
        scenario: 'sixteen tokens on absolute square 0',
      );
    });
  });

  // =========================================================================
  // D2 -- everything that is not a shared slot keeps 0.5 (case f).
  // =========================================================================
  group('D2: a one-seat disc keeps its mark at 0.5 of the disc (case f)', () {
    testWidgets('a single seat\'s token on a track cell, 344 board', (
      WidgetTester tester,
    ) async {
      const List<int> seats = <int>[0, 1, 2, 3];
      await tester.pumpWidget(
        _boardHarness(
          tokens: _tokensWith(seats, <int, Map<int, int>>{
            1: <int, int>{0: 5},
          }),
          seatsInPlay: seats,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        const <_Slot>[(1, 0)],
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'seat 1 alone on its progress 5',
      );
    });

    testWidgets('two tokens of the same seat on one track cell are not a '
        'shared slot, 344 board', (WidgetTester tester) async {
      const List<int> seats = <int>[0, 2];
      await tester.pumpWidget(
        _boardHarness(
          tokens: _tokensWith(seats, <int, Map<int, int>>{
            2: <int, int>{0: 20, 1: 20},
          }),
          seatsInPlay: seats,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        const <_Slot>[(2, 0), (2, 1)],
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'seat 2 tokens 0 and 1 together on progress 20',
      );
    });

    testWidgets('two seats on neighbouring cells do not share, 344 board', (
      WidgetTester tester,
    ) async {
      const List<int> seats = <int>[0, 1];
      await tester.pumpWidget(
        _boardHarness(
          tokens: _tokensWith(seats, <int, Map<int, int>>{
            0: <int, int>{0: 8},
            1: <int, int>{0: _progressAt(1, 9)},
          }),
          seatsInPlay: seats,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        const <_Slot>[(0, 0), (1, 0)],
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'seat 0 on square 8, seat 1 on square 9',
      );
    });

    testWidgets('every token in the yard (all four seats, 16 discs), 344 '
        'board', (WidgetTester tester) async {
      const List<int> seats = <int>[0, 1, 2, 3];
      await tester.pumpWidget(
        _boardHarness(tokens: _yardsOf(seats), seatsInPlay: seats),
      );
      await tester.pump();

      _expectAll(
        tester,
        <_Slot>[
          for (final int seat in seats)
            for (int i = 0; i < 4; i++) (seat, i),
        ],
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'all sixteen tokens in their yards',
      );
    });

    testWidgets('a home column token and a finished token of every seat, '
        '344 board', (WidgetTester tester) async {
      const List<int> seats = <int>[0, 1, 2, 3];
      await tester.pumpWidget(
        _boardHarness(
          tokens: <int, List<int>>{
            for (final int seat in seats) seat: <int>[52, 56, 57, 57],
          },
          seatsInPlay: seats,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        <_Slot>[
          for (final int seat in seats)
            for (int i = 0; i < 4; i++) (seat, i),
        ],
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'home column progress 52 and 56, finished 57 (x2)',
      );
    });

    testWidgets('a lone token on a 280 board keeps 0.5 (the floor decides '
        'only whether it paints)', (WidgetTester tester) async {
      const List<int> seats = <int>[0, 1];
      await tester.pumpWidget(
        _boardHarness(
          tokens: _tokensWith(seats, <int, Map<int, int>>{
            0: <int, int>{0: 30},
          }),
          seatsInPlay: seats,
          side: 280,
        ),
      );
      await tester.pump();

      _expectAll(
        tester,
        const <_Slot>[(0, 0)],
        side: 280,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario: 'seat 0 alone on progress 30, 280 board',
      );
    });
  });

  // =========================================================================
  // D2 -- shared is decided from the drawn layout, not from truth.
  // =========================================================================
  group('D2: shared is read from the drawn layout, not from truth', () {
    // Seat 0 token 0 walks 5 to 8, onto square 8 where seat 1 stands. One
    // step in, truth is already on the shared square but the disc is drawn
    // on a cell only it occupies.
    Future<void> startTravel(WidgetTester tester) async {
      const List<int> seats = <int>[0, 1];
      final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
      await tester.pumpWidget(
        MaterialApp(
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
                width: 344,
                height: 344,
                child: _Host(
                  key: hostKey,
                  tokens: _tokensWith(seats, <int, Map<int, int>>{
                    0: <int, int>{0: 5},
                    1: <int, int>{0: _progressAt(1, 8)},
                  }),
                  seatsInPlay: seats,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      hostKey.currentState!.setTokens(
        _tokensWith(seats, <int, Map<int, int>>{
          0: <int, int>{0: 8},
          1: <int, int>{0: _progressAt(1, 8)},
        }),
      );
      await tester.pump();
      await tester.pump(kTokenStepDuration);
    }

    testWidgets('a token mid-travel toward a shared square keeps the fan '
        'mark', (WidgetTester tester) async {
      await startTravel(tester);

      _expectMark(
        tester,
        seat: 0,
        index: 0,
        side: 344,
        discFraction: _fanDisc,
        markFraction: _fanMarkFraction,
        scenario:
            'seat 0 token 0 travelling 5 to 8 onto seat 1, one step in '
            '(truth already on the shared square)',
      );
    });

    testWidgets('the same two tokens, once the walk has landed, both take '
        'the shared mark', (WidgetTester tester) async {
      await startTravel(tester);
      for (int i = 0; i < 6; i++) {
        await tester.pump(kTokenStepDuration);
      }

      _expectAll(
        tester,
        const <_Slot>[(0, 0), (1, 0)],
        side: 344,
        discFraction: _sharedDisc,
        markFraction: _sharedMarkFraction,
        scenario: 'seat 0 and seat 1 together on square 8 after landing',
      );
    });
  });
}

/// Holds one board's tokens across rebuilds so a case can hand the board a
/// fresh snapshot the way a screen does.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.tokens, required this.seatsInPlay});

  final Map<int, List<int>> tokens;
  final List<int> seatsInPlay;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Map<int, List<int>> _tokens;

  @override
  void initState() {
    super.initState();
    _tokens = widget.tokens;
  }

  void setTokens(Map<int, List<int>> next) {
    setState(() {
      _tokens = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LudoBoard(tokens: _tokens, seatsInPlay: widget.seatsInPlay);
  }
}
