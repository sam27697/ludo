// Pixel proof of order 641 (work/ludo/orders/641-pieces-have-depth.md),
// decision D1' (flat-layer body, no shader), written from that contract's text
// alone. D2 (border) and D4 (cost) are not pixel claims.
//
// Round 6 (RESPEC 3, run 150). Measured by order 646's instrument: with the
// radial gradient of D1 on every token (no shadow) both stills runs died at
// capture 10; the guest froze for every process within about 1 s, the host
// emulator process went into an uninterruptible wait and grew about 200 MB, no
// OOM anywhere. The hang is the host's software renderer drawing the gradient
// shader inside the dimmed table's offscreen layer. The round 4 statement that
// the contact shadow, not the gradient, was the cause was a one-run bisect and
// was wrong: gradient-only has four deaths in four runs. The token therefore
// has no Gradient, no Shader, no MaskFilter, no BoxShadow and no saveLayer; the
// depth comes from flat fills. P3 (contact shadow) and P5 (hard shadow edge)
// stay removed since round 4.
//
// D1' geometry the probes are derived from. d is the drawn diameter and y is
// measured from the disc centre, down positive, in fractions of d:
//   1. base disc, radius 0.50, colour darker = lerp(seat, black, 0.22);
//   2. body disc, radius 0.40, centre y = -0.06 (bottom edge at y = +0.34,
//      leaving a darker crescent below it), colour seat;
//   3. highlight oval, width 0.44, height 0.20, centre y = -0.30 (so it spans
//      y = -0.40 to -0.20), colour lighter = lerp(seat, white, 0.35);
//   4. the border ring of D2, ink at 0.55, width max(1, 0.06 d), inside the
//      disc edge (0.44 d to 0.50 d).
// The seat mark (radius 0.25 d on the track) is drawn over the middle.
//
// What still holds for D1', and why:
//   P1 holds. 0.36 d above the centre falls inside the highlight oval, 0.36 d
//      below falls in the darker crescent (0.34 d to 0.44 d). The gap needed
//      is 0.04 relative luminance.
//   P2 holds. 0.36 d below is the darker crescent, which is the seat colour
//      mixed 22 percent with black and stays nearest to its own seat colour.
//   P4 holds unchanged. It probes the border ring at 0.47 d, which D1' keeps
//      exactly as it was.
//   P6 holds unchanged. It probes 0.55 d, outside the disc, where D1' paints
//      nothing.
//   H1 holds. 0.40 d to the right is just outside the body disc, so it reads
//      the darker base disc, still nearer to the seat colour than to paper;
//      0.62 d to the right is paper.
//   P7 is new, below.
//
// P7 flat body. On the vertical axis of each P1 track token the colour must
// take flat values, not ramp. From 0.27 d to 0.42 d below the centre every
// pixel is within 4 per channel of the seat colour or of darker, except at
// most 1 (the antialiased edge of the body disc at 0.34 d). From 0.33 d to
// 0.39 d above the centre every pixel is within 4 per channel of lighter, with
// no exception. A gradient passes through every colour between and fails.
// The 0.27 d start clears the seat mark (radius 0.25 d on the track): measured
// on D1', no pixel of either band is mark-coloured. The band is taken as the
// pixel rows whose centre lies inside it, in the pixel column that contains the
// disc centre.
//
// The exception counts are tighter than the first contract text (2 and 2),
// by the master's decision after this measurement. At d = 21 px the lower band
// holds 3 pixel rows and the upper band 1, so 2 exceptions could never fail
// the upper band and failed the lower band only when all three rows missed.
// Misses per token with no exception allowed, band lower (3 rows) / upper
// (1 row):
//   base gradient, seat 2 (yellow)         3 / 1
//   base gradient, seats 0, 1 and 3        2 / 1
//   D1' flat layers, every seat            1 / 0
// With 2 and 2 only seat 2 was red on the gradient. With 1 and 0 every seat
// is red on the gradient and green on D1'.
//
// Method. LudoBoard is mounted in a 450 x 450 physical viewport at device
// pixel ratio 1.0, so one cell is 30 px, inside one RepaintBoundary that is
// rendered with toImage(pixelRatio: 1.0) and read as rawStraightRgba. The
// harness is copied from test/c639_board_art_test.dart, not imported. No
// seatNames, turnSeat, legal or seatDice are passed, so no chip, glow, ring or
// die sits over a probe point.
//
// A token's drawn centre and diameter d are read from
// tester.getRect(find.byKey(Key('token-<seat>-<index>'))). H1 checks that this
// Semantics box is the drawn disc: a point 0.40 d to the right of its centre
// (inside the border, outside the seat mark) reads the seat colour, and a
// point 0.62 d to the right reads the paper, so the box is neither larger nor
// smaller than the painted circle.
//
// Every probe sits on the vertical axis through the centre. The seat mark
// covers the middle half of the disc on the track (radius 0.25 d) and the
// border starts at 0.44 d, so 0.36 d above and below is body only.
//
// Every case runs twice, with mySeat null and with mySeat 2 (the board
// rotates, so a seat's finished triangle and track arms change screen side).
// Every case collects all its misses and fails once, listing seat, token,
// case, the points, the colours and the scenario to re-run. There is no
// randomness: the scenario text is the seed.
//
// Reading choices, reported rather than invented around:
//
//   1. P1, P2 and P6 need a main-track cell that is not a safe square, not an
//      entry square, has no other token on it, and whose probe points fall on
//      plain track paper. The token of tokenIndex 0 sits 0.12 cell up and to
//      the left of its cell centre (the one-token fan). Cells are taken from
//      the two vertical arms (view column 6 or 8, rows 1 to 4 or 10 to 13)
//      whose neighbour above and below is also a plain track cell.
//   2. P4 finishes all sixteen tokens (progress 57), so every one of the four
//      spots of every triangle is probed. "The triangle's own colour" is read
//      from the very same pixel of a capture of the same board with no
//      finished token, so it is what the board paints there, not a colour
//      assumed from the palette. A harness failure is raised if that bare
//      pixel is not near the seat colour. The probe is straight down (screen
//      space) from the disc centre, 0.47 d, the middle of the border ring
//      (0.44 d to 0.50 d). The ordered 0.36 d body probe is not asserted: on
//      a 0.55 cell disc a correct D1 gradient is only 0.012 to 0.027 relative
//      luminance away from the seat colour there (seat 2 alone reaches 0.03),
//      so the threshold cannot be met by any correct implementation. The
//      gradient is proven by P1 on the track, where the disc is larger.
//   3. P6 probes 0.55 d below the centre of a track token. The ordered
//      0.57 d + 1 px probe is dropped: a hard shadow of the token's size
//      offset 0.07 d down ends at 0.57 d, so that pixel reads plain paper
//      (0.957) with the shadow present as well as without it, and it adds
//      nothing. The 0.55 d point (the pixel row just under the disc,
//      luminance 0.488 with such a shadow, a gap of 0.469) is the one that
//      sees it. If the probe pixel is on a grid line it is moved 1 px up
//      (towards the token, never down onto the next line) and named. Its
//      plain-paper reference is the pixel at the same row, 28 px right of
//      the cell's left edge: same cell, clear of the disc by more than 0.2 d,
//      off the grid lines at pixels 29 and 30.
//   4. flutter_test paints every BoxShadow without its blur by default
//      (debugDisableShadows), so P6 switches that flag off for its own capture
//      and restores it. The other cases run under the default.
//   5. P7 allows 1 exception in the lower band and none in the upper band;
//      see the P7 paragraph above for the row counts and the measurement.

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

const List<int> _allSeats = <int>[0, 1, 2, 3];

/// Minimum relative-luminance gaps the contract asks for.
const double _litGap = 0.04;
const double _finishedGap = 0.03;
const double _noShadowTolerance = 0.012;

// ---------------------------------------------------------------------------
// Harness (copied from test/c639_board_art_test.dart).
// ---------------------------------------------------------------------------

Widget _pixelHarness({
  required Map<int, List<int>> tokens,
  required int? mySeat,
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
          seatsInPlay: _allSeats,
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

// ---------------------------------------------------------------------------
// Pixels and colour arithmetic.
// ---------------------------------------------------------------------------

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

  /// Sum of absolute channel differences.
  double distanceTo(_Rgb o) =>
      (r - o.r).abs() + (g - o.g).abs() + (b - o.b).abs();
}

String _lum(_Rgb c) => c.luminance.toStringAsFixed(3);

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
// Geometry, always through the public geometry functions.
// ---------------------------------------------------------------------------

Set<BoardCell> _viewCells(Iterable<BoardCell> cells, int quarters) =>
    <BoardCell>{for (final BoardCell c in cells) toView(c, quarters)};

/// The 52 main-track cells in view space.
Set<BoardCell> _trackView(int quarters) => _viewCells(<BoardCell>[
  for (int p = 0; p < 52; p++) cellFor(seat: 0, progress: p),
], quarters);

/// The eight safe squares (the four entry squares included) in view space.
Set<BoardCell> _safeView(int quarters) => _viewCells(<BoardCell>[
  for (final int a in safeTrackSquares) safeSquareCell(a),
], quarters);

class _Placed {
  const _Placed(this.seat, this.tokenIndex, this.progress, this.cell);

  final int seat;
  final int tokenIndex;
  final int progress;
  final BoardCell cell;

  String get label =>
      'seat $seat token $tokenIndex (progress $progress, '
      'view cell (${cell.col}, ${cell.row}))';
}

/// One token per seat on a plain track cell of a vertical arm whose neighbours
/// above and below are plain track cells too, no two within 3 cells of each
/// other. Tokens of tokenIndex 0; the seat's other three stay in the yard.
List<_Placed> _plainTrackPlacements(int quarters) {
  final Set<BoardCell> track = _trackView(quarters);
  final Set<BoardCell> safe = _safeView(quarters);
  bool plain(BoardCell c) => track.contains(c) && !safe.contains(c);

  // Every plain vertical-arm candidate of each seat, in progress order.
  final Map<int, List<_Placed>> candidates = <int, List<_Placed>>{
    for (final int seat in _allSeats) seat: <_Placed>[],
  };
  for (final int seat in _allSeats) {
    for (int p = 1; p <= 50; p++) {
      final BoardCell v = toView(cellFor(seat: seat, progress: p), quarters);
      final bool arm =
          (v.col == 6 || v.col == 8) &&
          ((v.row >= 1 && v.row <= 4) || (v.row >= 10 && v.row <= 13));
      if (arm &&
          plain(v) &&
          plain(BoardCell(v.col, v.row - 1)) &&
          plain(BoardCell(v.col, v.row + 1))) {
        candidates[seat]!.add(_Placed(seat, 0, p, v));
      }
    }
  }

  // First combination, in seat then progress order, with no two within 3
  // cells of each other.
  List<_Placed>? search(List<_Placed> chosen) {
    if (chosen.length == _allSeats.length) {
      return chosen;
    }
    for (final _Placed c in candidates[_allSeats[chosen.length]]!) {
      final bool crowded = chosen.any(
        (_Placed o) =>
            math.max(
              (o.cell.col - c.cell.col).abs(),
              (o.cell.row - c.cell.row).abs(),
            ) <
            3,
      );
      if (crowded) {
        continue;
      }
      final List<_Placed>? found = search(<_Placed>[...chosen, c]);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  final List<_Placed>? found = search(<_Placed>[]);
  if (found == null) {
    fail(
      'C-641t harness: no combination of plain vertical-arm track cells, one '
      'per seat and 3 cells apart, exists with quarters $quarters, so the '
      'depth cases cannot be set up',
    );
  }
  return found;
}

Map<int, List<int>> _tokensFor(List<_Placed> placed) => <int, List<int>>{
  for (final int seat in _allSeats)
    seat: <int>[
      for (int i = 0; i < 4; i++)
        placed
                .where((_Placed p) => p.seat == seat && p.tokenIndex == i)
                .map((_Placed p) => p.progress)
                .firstOrNull ??
            -1,
    ],
};

/// Every token of every seat finished, on its fixed spot in its triangle.
List<_Placed> _finishedPlacements(int quarters) => <_Placed>[
  for (final int seat in _allSeats)
    for (int i = 0; i < 4; i++)
      _Placed(
        seat,
        i,
        57,
        toView(cellFor(seat: seat, progress: 57, tokenIndex: i), quarters),
      ),
];

/// A cell-grid line is drawn 1 px wide on every multiple of one cell, half on
/// each pixel beside it: pixels 30k - 1 and 30k.
bool _onGridLine(int pixel) => pixel % 30 == 0 || pixel % 30 == 29;

String _px(Offset o) =>
    '(${o.dx.toStringAsFixed(2)}, ${o.dy.toStringAsFixed(2)})';

// ---------------------------------------------------------------------------
// One rendered scene.
// ---------------------------------------------------------------------------

class _Scene {
  _Scene({
    required this.caseName,
    required this.mySeat,
    required this.placed,
    required this.frame,
    required this.discs,
  });

  final String caseName;
  final int? mySeat;
  final List<_Placed> placed;
  final _Frame frame;

  /// Each placed token's drawn box, board-local, from its Semantics widget.
  final Map<_Placed, Rect> discs;

  final List<String> misses = <String>[];

  String get scenario =>
      'LudoBoard 450x450 dpr 1.0, all four seats in play, mySeat '
      '${mySeat ?? 'null'}, tokens ${placed.map((_Placed p) => p.label).join('; ')}, '
      'no seatNames/turnSeat/legal/seatDice';

  void done() {
    if (misses.isEmpty) {
      return;
    }
    fail(
      'C-641t $caseName: ${misses.length} probe(s) failed.\n'
      '${misses.map((String m) => '  - $m').join('\n')}\n'
      'Scenario: $scenario. Reproduce: cd packages/ludo_client && '
      "flutter test test/c641_piece_depth_test.dart --plain-name '$caseName'",
    );
  }
}

Future<_Scene> _render(
  WidgetTester tester, {
  required String caseName,
  required int? mySeat,
  required List<_Placed> placed,
}) async {
  _pinViewportToBoard(tester);
  await tester.pumpWidget(
    _pixelHarness(tokens: _tokensFor(placed), mySeat: mySeat),
  );
  await tester.pump();
  final _Frame frame = await _capture(tester);
  final Offset origin = tester.getTopLeft(find.byType(LudoBoard));
  final Map<_Placed, Rect> discs = <_Placed, Rect>{};
  for (final _Placed p in placed) {
    final Finder token = find.byKey(Key('token-${p.seat}-${p.tokenIndex}'));
    if (token.evaluate().length != 1) {
      fail(
        'C-641t $caseName: expected exactly one token-${p.seat}-'
        '${p.tokenIndex} widget, found ${token.evaluate().length}',
      );
    }
    discs[p] = tester.getRect(token).shift(-origin);
  }
  return _Scene(
    caseName: caseName,
    mySeat: mySeat,
    placed: placed,
    frame: frame,
    discs: discs,
  );
}

// ---------------------------------------------------------------------------
// The cases.
// ---------------------------------------------------------------------------

void main() {
  for (final int? mySeat in <int?>[null, 2]) {
    final int q = viewQuarters(mySeat);
    final String view = 'mySeat ${mySeat ?? 'null'}';

    // The Semantics box is the drawn disc: the seat colour inside the border
    // on the right, paper outside it. The right-hand side is used because a
    // token of tokenIndex 0 sits left of its cell centre, so 0.62 d to the
    // right stays inside its own cell.
    testWidgets('H1 token box is the drawn disc, $view', (tester) async {
      final String name = 'H1 token box is the drawn disc, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _plainTrackPlacements(q),
      );
      final _Rgb paper = _Rgb.of(LudoColors.paperElevated);
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        if ((r.width - r.height).abs() > 0.01) {
          s.misses.add(
            '${p.label}: expected a square box, read ${r.width} x ${r.height}',
          );
          continue;
        }
        final double d = r.width;
        final Offset inside = r.center + Offset(0.40 * d, 0);
        final Offset outside = r.center + Offset(0.62 * d, 0);
        final _Rgb own = _Rgb.of(LudoColors.seats[p.seat]);
        final px1 = s.frame.at(inside);
        final px2 = s.frame.at(outside);
        if (px1.rgb.distanceTo(own) > px1.rgb.distanceTo(paper)) {
          s.misses.add(
            '${p.label}, H1 point 0.40 d right of the centre ${_px(inside)} = '
            'px (${px1.x}, ${px1.y}): expected the seat colour ${own.hex} '
            '(nearer than paper ${paper.hex}), read ${px1.rgb.hex}; box '
            '${r.width.toStringAsFixed(2)} px square at ${_px(r.center)}',
          );
        }
        if (px2.rgb.distanceTo(paper) > px2.rgb.distanceTo(own)) {
          s.misses.add(
            '${p.label}, H1 point 0.62 d right of the centre ${_px(outside)} '
            '= px (${px2.x}, ${px2.y}): expected paper ${paper.hex} (nearer '
            'than the seat colour ${own.hex}), read ${px2.rgb.hex}; box '
            '${r.width.toStringAsFixed(2)} px square at ${_px(r.center)}',
          );
        }
      }
      s.done();
    });

    // P1: lit from above. Relative luminance 0.36 d above the centre exceeds
    // that 0.36 d below by at least 0.04.
    testWidgets('P1 lit from above, $view', (tester) async {
      final String name = 'P1 lit from above, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _plainTrackPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        final Offset up = r.center - Offset(0, 0.36 * d);
        final Offset down = r.center + Offset(0, 0.36 * d);
        final pu = s.frame.at(up);
        final pd = s.frame.at(down);
        final double gap = pu.rgb.luminance - pd.rgb.luminance;
        if (gap < _litGap) {
          s.misses.add(
            '${p.label}, P1 above ${_px(up)} = px (${pu.x}, ${pu.y}) '
            '${pu.rgb.hex} luminance ${_lum(pu.rgb)}; below ${_px(down)} = px '
            '(${pd.x}, ${pd.y}) ${pd.rgb.hex} luminance ${_lum(pd.rgb)}: '
            'expected above brighter than below by at least $_litGap, read '
            '${gap.toStringAsFixed(3)} (d ${d.toStringAsFixed(2)} px)',
          );
        }
      }
      s.done();
    });

    // P2: still its seat colour. The point 0.36 d below the centre is nearer
    // (sum of absolute channel differences) to its own seat colour than to any
    // other seat colour.
    testWidgets('P2 still its seat colour, $view', (tester) async {
      final String name = 'P2 still its seat colour, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _plainTrackPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final Offset down = r.center + Offset(0, 0.36 * r.width);
        final pd = s.frame.at(down);
        final _Rgb own = _Rgb.of(LudoColors.seats[p.seat]);
        final double ownDistance = pd.rgb.distanceTo(own);
        for (final int other in _allSeats) {
          if (other == p.seat) {
            continue;
          }
          final _Rgb o = _Rgb.of(LudoColors.seats[other]);
          if (pd.rgb.distanceTo(o) <= ownDistance) {
            s.misses.add(
              '${p.label}, P2 below ${_px(down)} = px (${pd.x}, ${pd.y}) '
              '${pd.rgb.hex}: expected nearest to its own seat colour '
              '${own.hex} (distance ${ownDistance.toStringAsFixed(0)}), but '
              'seat $other ${o.hex} is at '
              '${pd.rgb.distanceTo(o).toStringAsFixed(0)}',
            );
          }
        }
      }
      s.done();
    });

    // P4: a finished piece stands apart from its own triangle with no shadow.
    // Every token of every seat is finished (progress 57), so each sits on one
    // of the four fixed spots. The point 0.47 d below its centre (the border
    // ring) differs from the triangle's own colour by at least 0.03 relative
    // luminance. The triangle's own colour is read from the same pixel of a
    // capture with no finished token.
    testWidgets('P4 finished piece apart from its triangle, $view', (
      tester,
    ) async {
      final String name = 'P4 finished piece apart from its triangle, $view';
      final _Scene bare = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: const <_Placed>[],
      );
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _finishedPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        final _Rgb own = _Rgb.of(LudoColors.seats[p.seat]);
        final Map<String, Offset> probes = <String, Offset>{
          '0.47 d below the centre (border ring)':
              r.center + Offset(0, 0.47 * d),
        };
        for (final MapEntry<String, Offset> e in probes.entries) {
          final px = s.frame.at(e.value);
          final ground = bare.frame.at(e.value);
          if (ground.rgb.distanceTo(own) > 60) {
            fail(
              'C-641t harness: ${p.label}: the bare-board pixel '
              '(${ground.x}, ${ground.y}) for the probe ${e.key} reads '
              '${ground.rgb.hex}, not near the seat colour ${own.hex}, so it '
              'is not the triangle. Scenario: ${s.scenario}',
            );
          }
          final double gap = (px.rgb.luminance - ground.rgb.luminance).abs();
          if (gap < _finishedGap) {
            s.misses.add(
              '${p.label}, P4 ${e.key} ${_px(e.value)} = px (${px.x}, ${px.y}) '
              '${px.rgb.hex} luminance ${_lum(px.rgb)}; triangle colour in '
              'the same pixel with no token ${ground.rgb.hex} luminance '
              '${_lum(ground.rgb)}: expected a difference of at least '
              '$_finishedGap, read ${gap.toStringAsFixed(3)} '
              '(d ${d.toStringAsFixed(2)} px)',
            );
          }
        }
      }
      s.done();
    });

    // P6: no shadow. The point 0.55 d under the centre of a token on the
    // track, just under the disc's bottom edge where a hard shadow of the
    // token's size offset 0.07 d down would show, is within 0.012 relative
    // luminance of plain paper in the same cell away from the token.
    testWidgets('P6 no shadow under the token, $view', (tester) async {
      final String name = 'P6 no shadow under the token, $view';
      // flutter_test replaces every BoxShadow blur with a hard block
      // (debugDisableShadows is true under testWidgets). Draw the real shadows
      // for this capture only and put the flag back before the test ends.
      debugDisableShadows = false;
      final _Scene s;
      try {
        s = await _render(
          tester,
          caseName: name,
          mySeat: mySeat,
          placed: _plainTrackPlacements(q),
        );
      } finally {
        debugDisableShadows = true;
      }
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        final Map<String, double> depths = <String, double>{'0.55 d': 0.55 * d};
        for (final MapEntry<String, double> e in depths.entries) {
          Offset below = r.center + Offset(0, e.value);
          String moved = '';
          if (_onGridLine(below.dy.floor())) {
            moved =
                '; the probe ${_px(below)} was on the grid line at pixel row '
                '${below.dy.floor()}, moved 1 px up';
            below = below - const Offset(0, 1);
          }
          final Offset reference = Offset(p.cell.col * _cell + 28.5, below.dy);
          if (_onGridLine(below.dy.floor()) ||
              _onGridLine(below.dx.floor()) ||
              _onGridLine(reference.dx.floor()) ||
              below.dy >= (p.cell.row + 1) * _cell ||
              (reference - r.center).distance < 0.7 * d) {
            fail(
              'C-641t harness: ${p.label}: a P6 probe is unusable (probe '
              '${e.key} ${_px(below)}, reference ${_px(reference)}, disc '
              'centre ${_px(r.center)}, d ${d.toStringAsFixed(2)}). '
              'Scenario: ${s.scenario}',
            );
          }
          final pb = s.frame.at(below);
          final pr = s.frame.at(reference);
          final double gap = (pb.rgb.luminance - pr.rgb.luminance).abs();
          if (gap > _noShadowTolerance) {
            s.misses.add(
              '${p.label}, P6 ${e.key} under the centre ${_px(below)} = px '
              '(${pb.x}, ${pb.y}) ${pb.rgb.hex} luminance ${_lum(pb.rgb)}; '
              'paper reference in the same cell ${_px(reference)} = px '
              '(${pr.x}, ${pr.y}) ${pr.rgb.hex} luminance ${_lum(pr.rgb)}: '
              'expected a difference of at most $_noShadowTolerance, read '
              '${gap.toStringAsFixed(3)} (d ${d.toStringAsFixed(2)} px)$moved',
            );
          }
        }
      }
      s.done();
    });

    // P7: flat body. D1' draws the body from flat fills only: a darker base
    // disc, a seat-colour body disc, a lighter highlight oval. So on the
    // vertical axis the colour takes a few values and steps between them, it
    // does not ramp. Below the centre, from 0.27 d to 0.42 d, every pixel is
    // within 4 per channel of the seat colour or of darker (at most 1 miss,
    // the antialiased edge of the body disc). Above the centre, from 0.33 d to
    // 0.39 d, every pixel is within 4 per channel of lighter (no
    // miss). A gradient fails this: it passes through every colour between.
    testWidgets('P7 flat body, $view', (tester) async {
      final String name = 'P7 flat body, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _plainTrackPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        final Color seatColor = LudoColors.seats[p.seat];
        final _Rgb seat = _Rgb.of(seatColor);
        final _Rgb darker = _Rgb.of(Color.lerp(seatColor, Colors.black, 0.22)!);
        final _Rgb lighter = _Rgb.of(
          Color.lerp(seatColor, Colors.white, 0.35)!,
        );
        final int column = r.center.dx.floor();

        // The pixel rows whose centre lies in [from, to] times d from the
        // disc centre, down positive.
        List<int> rows(double from, double to) => <int>[
          for (
            int y = (r.center.dy + from * d - 0.5).ceil();
            y + 0.5 <= r.center.dy + to * d;
            y++
          )
            y,
        ];

        void probe(
          String band,
          List<int> ys,
          Map<String, _Rgb> allowed,
          int maxMisses,
        ) {
          if (ys.isEmpty) {
            fail(
              'C-641t harness: ${p.label}: P7 band $band holds no pixel row '
              '(d ${d.toStringAsFixed(2)} px, centre ${_px(r.center)}). '
              'Scenario: ${s.scenario}',
            );
          }
          final List<String> missed = <String>[];
          for (final int y in ys) {
            final px = s.frame.at(Offset(column + 0.5, y + 0.5));
            final bool near = allowed.values.any(
              (_Rgb a) =>
                  (px.rgb.r - a.r).abs() <= 4 &&
                  (px.rgb.g - a.g).abs() <= 4 &&
                  (px.rgb.b - a.b).abs() <= 4,
            );
            if (!near) {
              missed.add('px (${px.x}, ${px.y}) ${px.rgb.hex}');
            }
          }
          if (missed.length > maxMisses) {
            s.misses.add(
              '${p.label}, P7 band $band on the axis, pixel rows '
              '${ys.first}..${ys.last} of column $column: expected every '
              'pixel within 4 per channel of ${allowed.entries.map((e) => '${e.key} ${e.value.hex}').join(' or ')} '
              'with at most $maxMisses exception(s), read ${missed.length} '
              'exceptions of ${ys.length}: ${missed.join(', ')} '
              '(d ${d.toStringAsFixed(2)} px)',
            );
          }
        }

        probe(
          '0.27 d to 0.42 d below the centre',
          rows(0.27, 0.42),
          <String, _Rgb>{'seat': seat, 'darker': darker},
          1,
        );
        probe(
          '0.33 d to 0.39 d above the centre',
          rows(-0.39, -0.33),
          <String, _Rgb>{'lighter': lighter},
          0,
        );
      }
      s.done();
    });
  }
}
