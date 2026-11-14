// Pixel proof of order 639 (work/ludo/orders/639-board-reads-as-ludo.md),
// decisions D1 to D6, written from that contract's text alone. D7 to D9 are
// judged on frames by the master and are not tested here.
//
// Method. LudoBoard is mounted in a 450 x 450 physical viewport at device
// pixel ratio 1.0, so one cell (s) is 30 px, inside one RepaintBoundary that
// is rendered with toImage(pixelRatio: 1.0) and read as rawStraightRgba. The
// harness is copied from test/board_seat_identity_test.dart, not imported.
// No seatNames, turnSeat or seatDice are passed, so no chip, glow or die sits
// over a probe point.
//
// Every expected colour is computed here from LudoColors and the alphas the
// contract names, with the source-over formula (_over), never typed as hex.
// Each channel is compared with a tolerance of 6 out of 255. Every probe is
// derived through viewQuarters / toView / cellFor, so each case runs twice:
// once with mySeat null and once with mySeat 2 (the board rotates).
//
// Every case collects all its misses and fails once, listing seat, case, the
// point in cells and pixels, both colours and the scenario to re-run.
//
// Reading choices, reported rather than invented around:
//
//   1. B5 asks for "the midpoint" of the centre block's side. That point is
//      on the block edge the contract itself defines, and the rule is to stay
//      3 px clear of every defined edge, so the first B5 probe is the
//      midpoint moved 0.15 s (4.5 px) toward the board centre. The second is
//      the contract's own 0.5 s.
//   2. B8 reads the entry square at a point 0.15 s from the cell's top-left
//      corner, not at its centre: every entry square carries a safe-square
//      star (a separate painter, out of this order) at the centre of the
//      cell, and the contract's alpha 0.85 over paperElevated describes the
//      fill, not the star.
//   3. B6 measures the shared edge of two cells, so it cannot keep 3 px away
//      from it. A 1 px line centred on an integer pixel coordinate lands half
//      on each of the two pixels beside the edge, so the darker of those two
//      pixels is the one compared with the cell interior.
//   4. The sampled pixel must be opaque (alpha 255, within the tolerance):
//      the contract composites every fill over dieFace or paperElevated, so
//      a see-through pixel means the board has no base under the fills.
//   5. B3 and B4 are also run on the 2-seat board (the faded alphas 0.035
//      and 0.098), and B7 on the 2-seat board (absent seats at 0.1575), and
//      B5 checks seats 0 and 2 opaque on the 2-seat board. The contract
//      states those alphas in D2, D3, D5 and D6.
//   6. Paper-elevated at 0.65 (today) and opaque (the contract) read within 3
//      per channel of each other over this board's base, so the tolerance
//      of 6 cannot separate them. The B6 interior check is therefore also
//      run with a tolerance of 2 as its own case.

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
import 'package:ludo_client/src/theme.dart';

const double _boardSide = 450;
const double _cell = _boardSide / 15;
const double _tolerance = 6;

/// The contract's fade for a seat that is not in play.
const double _absentFade = 0.35;

const List<int> _allSeats = <int>[0, 1, 2, 3];
const List<int> _pairSeats = <int>[0, 2];

// ---------------------------------------------------------------------------
// Harness (copied from test/board_seat_identity_test.dart).
// ---------------------------------------------------------------------------

Widget _pixelHarness({
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  int? mySeat,
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
        child: LudoBoard(
          tokens: tokens,
          seatsInPlay: seatsInPlay,
          mySeat: mySeat,
        ),
      ),
    ),
  );
}

void _pinViewportToBoard(WidgetTester tester) {
  tester.view.physicalSize = const Size(_boardSide, _boardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Every token of every seat on the main track, none in a yard, none in the
/// home column, none finished. Progress 20 is far from every probe below.
Map<int, List<int>> _allOnTrack() => <int, List<int>>{
  for (final int seat in _allSeats) seat: <int>[20, 20, 20, 20],
};

// ---------------------------------------------------------------------------
// Pixels and colour arithmetic.
// ---------------------------------------------------------------------------

/// A colour in 0..255 channels, kept as doubles so blends do not round twice.
class _Rgb {
  const _Rgb(this.r, this.g, this.b);

  factory _Rgb.of(Color c) => _Rgb(c.r * 255, c.g * 255, c.b * 255);

  final double r;
  final double g;
  final double b;

  String get hex {
    String two(double v) =>
        v.round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${two(r)}${two(g)}${two(b)}';
  }

  /// WCAG relative luminance, sRGB linearised.
  double get luminance {
    double lin(double v) {
      final double c = v / 255;
      return c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }
}

/// Standard source-over: [top] at [alpha] drawn over the opaque [under].
_Rgb _over(_Rgb under, Color top, double alpha) {
  final _Rgb t = _Rgb.of(top);
  return _Rgb(
    t.r * alpha + under.r * (1 - alpha),
    t.g * alpha + under.g * (1 - alpha),
    t.b * alpha + under.b * (1 - alpha),
  );
}

_Rgb get _dieFace => _Rgb.of(LudoColors.dieFace);
_Rgb get _paperElevated => _Rgb.of(LudoColors.paperElevated);

/// The fade the contract applies to every alpha of a seat not in play.
double _alphaFor(double alpha, {required bool inPlay}) =>
    inPlay ? alpha : alpha * _absentFade;

class _Frame {
  _Frame(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  /// The pixel that contains board-local [local] (x and y in logical px).
  ({_Rgb rgb, int alpha, int x, int y}) at(Offset local) {
    final int x = local.dx.floor().clamp(0, width - 1);
    final int y = local.dy.floor().clamp(0, height - 1);
    final int i = (y * width + x) * 4;
    return (
      rgb: _Rgb(
        data.getUint8(i).toDouble(),
        data.getUint8(i + 1).toDouble(),
        data.getUint8(i + 2).toDouble(),
      ),
      alpha: data.getUint8(i + 3),
      x: x,
      y: y,
    );
  }
}

/// Renders the single [RepaintBoundary] in the tree to an image and reads its
/// raw RGBA bytes, once, so a case can probe many points off one frame.
Future<_Frame> _capture(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  expect(
    boundary.size,
    const Size(_boardSide, _boardSide),
    reason:
        'harness: the board must fill the 450 x 450 viewport so that one '
        'cell is 30 px; got ${boundary.size}',
  );
  ui.Image? image;
  ByteData? pixels;
  await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
    pixels = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image = img;
  });
  return _Frame(image!.width, image!.height, pixels!);
}

// ---------------------------------------------------------------------------
// View-space geometry, always through the public geometry functions.
// ---------------------------------------------------------------------------

/// The top-left cell of [seat]'s yard quadrant after the board is turned for
/// [quarters]: the bounding box of the four rotated corner cells.
({int col, int row}) _viewQuadrantOrigin(int seat, int quarters) {
  final BoardCell o = yardQuadrantOrigin(seat);
  final int last = yardQuadrantSide - 1;
  final List<BoardCell> corners = <BoardCell>[
    toView(BoardCell(o.col, o.row), quarters),
    toView(BoardCell(o.col + last, o.row), quarters),
    toView(BoardCell(o.col, o.row + last), quarters),
    toView(BoardCell(o.col + last, o.row + last), quarters),
  ];
  return (
    col: corners.map((BoardCell c) => c.col).reduce(math.min),
    row: corners.map((BoardCell c) => c.row).reduce(math.min),
  );
}

/// Board-local px of the point ([u], [v]) cells from [seat]'s viewed yard
/// quadrant's top-left corner.
Offset _quadrantPoint(int seat, int quarters, double u, double v) {
  final ({int col, int row}) o = _viewQuadrantOrigin(seat, quarters);
  return Offset((o.col + u) * _cell, (o.row + v) * _cell);
}

/// Board-local px of the centre of the viewed [cell].
Offset _cellCentre(BoardCell viewed) =>
    Offset((viewed.col + 0.5) * _cell, (viewed.row + 0.5) * _cell);

String _cells(Offset px) =>
    '(${(px.dx / _cell).toStringAsFixed(2)}, ${(px.dy / _cell).toStringAsFixed(2)}) cells';

// ---------------------------------------------------------------------------
// Probe collector.
// ---------------------------------------------------------------------------

class _Probe {
  _Probe({
    required this.testName,
    required this.scenario,
    required this.frame,
    this.tolerance = _tolerance,
  });

  final double tolerance;
  final String testName;
  final String scenario;
  final _Frame frame;
  final List<String> misses = <String>[];

  /// Checks that the pixel at [at] reads [want] within the tolerance and is
  /// opaque. [what] names the seat, the case and the point.
  void expectColor(String what, Offset at, _Rgb want, String wantNote) {
    final px = frame.at(at);
    final bool colourOk =
        (px.rgb.r - want.r).abs() <= tolerance &&
        (px.rgb.g - want.g).abs() <= tolerance &&
        (px.rgb.b - want.b).abs() <= tolerance;
    final bool opaque = px.alpha >= 255 - tolerance;
    if (colourOk && opaque) {
      return;
    }
    misses.add(
      '$what at ${_cells(at)} = px (${px.x}, ${px.y}): expected '
      '${want.hex} ($wantNote), read ${px.rgb.hex} alpha ${px.alpha}',
    );
  }

  void done() {
    if (misses.isEmpty) {
      return;
    }
    fail(
      'C-639t $testName: ${misses.length} probe(s) read the wrong colour '
      '(tolerance $tolerance per channel).\n'
      '${misses.map((String m) => '  - $m').join('\n')}\n'
      'Scenario: $scenario. Reproduce: cd packages/ludo_client && '
      "flutter test test/c639_board_art_test.dart --plain-name '$testName'",
    );
  }
}

Future<_Probe> _render(
  WidgetTester tester, {
  required String testName,
  required List<int> seatsInPlay,
  required int? mySeat,
  double tolerance = _tolerance,
}) async {
  _pinViewportToBoard(tester);
  await tester.pumpWidget(
    _pixelHarness(
      tokens: _allOnTrack(),
      seatsInPlay: seatsInPlay,
      mySeat: mySeat,
    ),
  );
  await tester.pump();
  final _Frame frame = await _capture(tester);
  return _Probe(
    testName: testName,
    scenario:
        'LudoBoard 450x450 dpr 1.0, seatsInPlay $seatsInPlay, mySeat '
        '$mySeat, every token at progress 20, no seatNames/turnSeat/seatDice',
    frame: frame,
    tolerance: tolerance,
  );
}

// ---------------------------------------------------------------------------
// The cases.
// ---------------------------------------------------------------------------

void main() {
  for (final int? mySeat in <int?>[null, 2]) {
    final int q = viewQuarters(mySeat);
    final String view = 'mySeat ${mySeat ?? 'null'}';

    // D1: the yard quadrant is the seat colour, alpha 1.0 over dieFace. The
    // two points lie in the outer 0.5 cell, outside the panel (D2).
    testWidgets('B1 band, 4 seats, $view', (tester) async {
      final String name = 'B1 band, 4 seats, $view';
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final _Rgb want = _over(_dieFace, LudoColors.seats[seat], 1.0);
        for (final ({double u, double v}) p in <({double u, double v})>[
          (u: 3.0, v: 0.25),
          (u: 0.25, v: 3.0),
        ]) {
          probe.expectColor(
            'seat $seat, B1 band (u=${p.u}, v=${p.v})',
            _quadrantPoint(seat, q, p.u, p.v),
            want,
            'seat colour alpha 1.0 over dieFace',
          );
        }
      }
      probe.done();
    });

    // D1 faded: absent seats 1 and 3 read alpha 0.35 over dieFace.
    testWidgets('B2 band, absent seats, $view', (tester) async {
      final String name = 'B2 band, absent seats, $view';
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: _pairSeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final bool inPlay = _pairSeats.contains(seat);
        final double alpha = _alphaFor(1.0, inPlay: inPlay);
        final _Rgb want = _over(_dieFace, LudoColors.seats[seat], alpha);
        for (final ({double u, double v}) p in <({double u, double v})>[
          (u: 3.0, v: 0.25),
          (u: 0.25, v: 3.0),
        ]) {
          probe.expectColor(
            'seat $seat (${inPlay ? 'in play' : 'absent'}), B2 band '
                '(u=${p.u}, v=${p.v})',
            _quadrantPoint(seat, q, p.u, p.v),
            want,
            'seat colour alpha $alpha over dieFace',
          );
        }
      }
      probe.done();
    });

    // D2 and D4: the panel, and no line through the yard. Each point sat on
    // an old grid line (column 3 or row 3 of the quadrant).
    Future<void> panelCase(
      WidgetTester tester,
      String name,
      List<int> inPlaySeats,
    ) async {
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: inPlaySeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final bool inPlay = inPlaySeats.contains(seat);
        final double alpha = _alphaFor(0.10, inPlay: inPlay);
        final _Rgb want = _over(_dieFace, LudoColors.seats[seat], alpha);
        for (final ({double u, double v}) p in <({double u, double v})>[
          (u: 3.0, v: 2.2),
          (u: 2.2, v: 3.0),
          (u: 3.0, v: 3.8),
        ]) {
          probe.expectColor(
            'seat $seat (${inPlay ? 'in play' : 'absent'}), panel '
                '(u=${p.u}, v=${p.v})',
            _quadrantPoint(seat, q, p.u, p.v),
            want,
            'dieFace under seat colour alpha $alpha',
          );
        }
      }
      probe.done();
    }

    testWidgets('B3 panel and no grid in the yard, 4 seats, $view', (
      tester,
    ) async {
      await panelCase(
        tester,
        'B3 panel and no grid in the yard, 4 seats, $view',
        _allSeats,
      );
    });

    testWidgets('B3 panel and no grid in the yard, 2 seats, $view', (
      tester,
    ) async {
      await panelCase(
        tester,
        'B3 panel and no grid in the yard, 2 seats, $view',
        _pairSeats,
      );
    });

    // D3: a well under each yard slot, alpha 0.28 over the panel. The centre
    // of the slot and a point 0.2 s from it toward the quadrant's centre.
    Future<void> wellCase(
      WidgetTester tester,
      String name,
      List<int> inPlaySeats,
    ) async {
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: inPlaySeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final bool inPlay = inPlaySeats.contains(seat);
        final Color seatColor = LudoColors.seats[seat];
        final _Rgb panel = _over(
          _dieFace,
          seatColor,
          _alphaFor(0.10, inPlay: inPlay),
        );
        final double wellAlpha = _alphaFor(0.28, inPlay: inPlay);
        final _Rgb want = _over(panel, seatColor, wellAlpha);
        final ({int col, int row}) origin = _viewQuadrantOrigin(seat, q);
        final Offset quadrantCentre = Offset(
          (origin.col + 3) * _cell,
          (origin.row + 3) * _cell,
        );
        for (var slot = 0; slot < 4; slot++) {
          final Offset centre = _cellCentre(
            toView(cellFor(seat: seat, progress: -1, tokenIndex: slot), q),
          );
          final Offset toward = quadrantCentre - centre;
          final Offset inward =
              centre + toward / toward.distance * (0.2 * _cell);
          probe.expectColor(
            'seat $seat (${inPlay ? 'in play' : 'absent'}), well $slot centre',
            centre,
            want,
            'panel under seat colour alpha $wellAlpha',
          );
          probe.expectColor(
            'seat $seat (${inPlay ? 'in play' : 'absent'}), well $slot, 0.2 s '
                'toward the quadrant centre',
            inward,
            want,
            'panel under seat colour alpha $wellAlpha',
          );
        }
      }
      probe.done();
    }

    testWidgets('B4 wells, 4 seats, $view', (tester) async {
      await wellCase(tester, 'B4 wells, 4 seats, $view', _allSeats);
    });

    testWidgets('B4 wells, 2 seats, $view', (tester) async {
      await wellCase(tester, 'B4 wells, 2 seats, $view', _pairSeats);
    });

    // D6: the centre home is four triangles meeting at the centre point.
    // Seat k's base lies on the side of the block that touches the view cell
    // of progress 56.
    Future<void> centreCase(
      WidgetTester tester,
      String name,
      List<int> inPlaySeats,
    ) async {
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: inPlaySeats,
        mySeat: mySeat,
      );
      const Offset boardCentre = Offset(7.5 * _cell, 7.5 * _cell);
      for (final int seat in _allSeats) {
        final bool inPlay = inPlaySeats.contains(seat);
        final BoardCell outside = toView(cellFor(seat: seat, progress: 56), q);
        final Offset sideMid;
        if (outside.col == 5 && outside.row >= 6 && outside.row <= 8) {
          sideMid = const Offset(6 * _cell, 7.5 * _cell);
        } else if (outside.col == 9 && outside.row >= 6 && outside.row <= 8) {
          sideMid = const Offset(9 * _cell, 7.5 * _cell);
        } else if (outside.row == 5 && outside.col >= 6 && outside.col <= 8) {
          sideMid = const Offset(7.5 * _cell, 6 * _cell);
        } else if (outside.row == 9 && outside.col >= 6 && outside.col <= 8) {
          sideMid = const Offset(7.5 * _cell, 9 * _cell);
        } else {
          fail(
            'C-639t $name: seat $seat progress 56 maps to view cell '
            '$outside, which does not touch a side of the centre 3 x 3 block '
            '(scenario: ${probe.scenario})',
          );
        }
        final Offset unit =
            (boardCentre - sideMid) / (boardCentre - sideMid).distance;
        final double alpha = _alphaFor(1.0, inPlay: inPlay);
        final _Rgb want = _over(_dieFace, LudoColors.seats[seat], alpha);
        final String side = outside.col == 5
            ? 'left'
            : outside.col == 9
            ? 'right'
            : outside.row == 5
            ? 'top'
            : 'bottom';
        probe.expectColor(
          'seat $seat (${inPlay ? 'in play' : 'absent'}), centre triangle '
              '(base on the $side side), side midpoint moved 0.15 s inward',
          sideMid + unit * (0.15 * _cell),
          want,
          'seat colour alpha $alpha over dieFace',
        );
        probe.expectColor(
          'seat $seat (${inPlay ? 'in play' : 'absent'}), centre triangle '
              '(base on the $side side), 0.5 s from the side midpoint toward the '
              'board centre',
          sideMid + unit * (0.5 * _cell),
          want,
          'seat colour alpha $alpha over dieFace',
        );
      }
      probe.done();
    }

    testWidgets('B5 centre home, 4 seats, $view', (tester) async {
      await centreCase(tester, 'B5 centre home, 4 seats, $view', _allSeats);
    });

    testWidgets('B5 centre home, 2 seats, $view', (tester) async {
      await centreCase(tester, 'B5 centre home, 2 seats, $view', _pairSeats);
    });

    // D4 and D5: the main-track grid stays, on an opaque paperElevated cell.
    // Seat 0 progress 2 and 3 are plain track cells (not safe, not entry).
    testWidgets('B6 track grid stays, $view', (tester) async {
      final String name = 'B6 track grid stays, $view';
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      final BoardCell a = toView(cellFor(seat: 0, progress: 2), q);
      final BoardCell b = toView(cellFor(seat: 0, progress: 3), q);
      final Offset centreA = _cellCentre(a);
      final Offset centreB = _cellCentre(b);
      probe.expectColor(
        'B6 interior of seat 0 progress 2 (view cell $a)',
        centreA,
        _paperElevated,
        'paperElevated, opaque',
      );
      probe.expectColor(
        'B6 interior of seat 0 progress 3 (view cell $b)',
        centreB,
        _paperElevated,
        'paperElevated, opaque',
      );
      // The shared edge: the two pixels either side of it, the darker wins.
      final Offset mid = (centreA + centreB) / 2;
      final bool verticalEdge = a.row == b.row;
      final Offset before = verticalEdge
          ? mid - const Offset(1, 0)
          : mid - const Offset(0, 1);
      final px1 = probe.frame.at(before);
      final px2 = probe.frame.at(mid);
      final double edgeLum = math.min(px1.rgb.luminance, px2.rgb.luminance);
      final String darker = px1.rgb.luminance <= px2.rgb.luminance
          ? px1.rgb.hex
          : px2.rgb.hex;
      final double cellLum = _paperElevated.luminance;
      if (cellLum - edgeLum < 0.05) {
        probe.misses.add(
          'B6 shared edge of view cells $a and $b at ${_cells(mid)} (pixels '
          '(${px1.x}, ${px1.y}) and (${px2.x}, ${px2.y})): expected a line '
          'at least 0.05 relative luminance darker than the cell interior '
          '(${_paperElevated.hex}, luminance ${cellLum.toStringAsFixed(3)}), '
          'darker edge pixel read $darker (luminance '
          '${edgeLum.toStringAsFixed(3)}), difference '
          '${(cellLum - edgeLum).toStringAsFixed(3)}',
        );
      }
      probe.done();
    });

    // D5 again, tighter. paperElevated opaque and paperElevated at today's
    // 0.65 over the near-white base differ by 3 per channel at most, which the
    // tolerance of 6 cannot tell apart, so this case reads the same two
    // interiors with a tolerance of 2. A solid opaque fill reads exact.
    testWidgets('B6 interior is opaque paperElevated, tight, $view', (
      tester,
    ) async {
      final String name = 'B6 interior is opaque paperElevated, tight, $view';
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: _allSeats,
        mySeat: mySeat,
        tolerance: 2,
      );
      for (final int progress in <int>[2, 3]) {
        final BoardCell cell = toView(cellFor(seat: 0, progress: progress), q);
        probe.expectColor(
          'B6 interior of seat 0 progress $progress (view cell $cell)',
          _cellCentre(cell),
          _paperElevated,
          'paperElevated, opaque',
        );
      }
      probe.done();
    });

    // D5: home column cells, seat colour alpha 0.45 over paperElevated.
    Future<void> columnCase(
      WidgetTester tester,
      String name,
      List<int> inPlaySeats,
    ) async {
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: inPlaySeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final bool inPlay = inPlaySeats.contains(seat);
        if (!inPlay && inPlaySeats.length == 4) {
          continue;
        }
        final double alpha = _alphaFor(0.45, inPlay: inPlay);
        final BoardCell cell = toView(cellFor(seat: seat, progress: 54), q);
        probe.expectColor(
          'seat $seat (${inPlay ? 'in play' : 'absent'}), home column '
              'progress 54, view cell $cell',
          _cellCentre(cell),
          _over(_paperElevated, LudoColors.seats[seat], alpha),
          'seat colour alpha $alpha over paperElevated',
        );
      }
      probe.done();
    }

    testWidgets('B7 home column, 4 seats, $view', (tester) async {
      await columnCase(tester, 'B7 home column, 4 seats, $view', _allSeats);
    });

    testWidgets('B7 home column, 2 seats, $view', (tester) async {
      await columnCase(tester, 'B7 home column, 2 seats, $view', _pairSeats);
    });

    // D5 unchanged: the entry square, seat colour alpha 0.85 over the track
    // fill. Read 0.15 s in from the cell's top-left corner, clear of the
    // safe-square star at the cell centre.
    testWidgets('B8 entry square unchanged, $view', (tester) async {
      final String name = 'B8 entry square unchanged, $view';
      final _Probe probe = await _render(
        tester,
        testName: name,
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      for (final int seat in _allSeats) {
        final BoardCell cell = toView(cellFor(seat: seat, progress: 0), q);
        final Offset corner = Offset(
          (cell.col + 0.15) * _cell,
          (cell.row + 0.15) * _cell,
        );
        probe.expectColor(
          'seat $seat, entry square (progress 0), view cell $cell, 0.15 s '
              'from its top-left corner',
          corner,
          _over(_paperElevated, LudoColors.seats[seat], 0.85),
          'seat colour alpha 0.85 over paperElevated',
        );
      }
      probe.done();
    });

    // D3' (round 2): a token at progress -1 takes no fan. Its centre is the
    // centre of its yard slot cell, so it sits in its well. Read from the
    // `token-<seat>-<index>` widget, not recomputed from the layout.
    testWidgets('B9 yard tokens sit in their wells, $view', (tester) async {
      final String name = 'B9 yard tokens sit in their wells, $view';
      _pinViewportToBoard(tester);
      await tester.pumpWidget(
        _pixelHarness(
          tokens: <int, List<int>>{
            for (final int seat in _allSeats) seat: <int>[-1, -1, -1, -1],
          },
          seatsInPlay: _allSeats,
          mySeat: mySeat,
        ),
      );
      await tester.pump();
      final Offset origin = tester.getTopLeft(find.byType(LudoBoard));
      final List<String> misses = <String>[];
      for (final int seat in _allSeats) {
        for (int index = 0; index < 4; index++) {
          final Finder token = find.byKey(Key('token-$seat-$index'));
          if (token.evaluate().length != 1) {
            misses.add(
              'seat $seat token $index: expected exactly one '
              'token-$seat-$index widget, found ${token.evaluate().length}',
            );
            continue;
          }
          final BoardCell slot = toView(
            cellFor(seat: seat, progress: -1, tokenIndex: index),
            q,
          );
          final Offset want = _cellCentre(slot);
          final Offset got = tester.getCenter(token) - origin;
          final double off = (got - want).distance;
          if (off > 0.5) {
            misses.add(
              'seat $seat token $index: expected centre ${_cells(want)} '
              '(px ${want.dx.toStringAsFixed(2)}, '
              '${want.dy.toStringAsFixed(2)}, the centre of yard slot view '
              'cell $slot), read px ${got.dx.toStringAsFixed(2)}, '
              '${got.dy.toStringAsFixed(2)}, ${off.toStringAsFixed(2)} px '
              'off (tolerance 0.5 px)',
            );
          }
        }
      }
      if (misses.isNotEmpty) {
        fail(
          'C-639t $name: ${misses.length} yard token(s) are not centred in '
          'their well.\n'
          '${misses.map((String m) => '  - $m').join('\n')}\n'
          'Scenario: LudoBoard 450x450 dpr 1.0, seatsInPlay $_allSeats, '
          'mySeat $mySeat, every token at progress -1. Reproduce: cd '
          'packages/ludo_client && flutter test '
          "test/c639_board_art_test.dart --plain-name '$name'",
        );
      }
    });
  }
}
