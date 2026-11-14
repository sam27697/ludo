// Pixel proof of order 641 (work/ludo/orders/641-pieces-have-depth.md),
// decisions D1 (body gradient) and D3 (contact shadow), written from that
// contract's text alone. D2 (border) and D4 (cost) are not pixel claims.
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
// covers the middle half of the disc (radius 0.25 d) and the border starts at
// 0.44 d, so 0.36 d above and below is body only.
//
// Every case runs twice, with mySeat null and with mySeat 2 (the board
// rotates, so a seat's finished triangle and track arms change screen side).
// Every case collects all its misses and fails once, listing seat, token,
// case, the points, the colours and the scenario to re-run. There is no
// randomness: the scenario text is the seed.
//
// Reading choices, reported rather than invented around:
//
//   1. P1 to P3 need a main-track cell that is not a safe square, not an
//      entry square, has no other token on it, and whose probe points fall on
//      plain track paper. The token of tokenIndex 0 sits 0.12 cell up and to
//      the left of its cell centre (the one-token fan), so a probe 0.55 d
//      above its centre lands 0.15 px beyond the cell's top edge, in the
//      neighbouring cell and on that edge's grid line. Cells are therefore
//      taken from the two vertical arms (view column 6 or 8, rows 1 to 4 or
//      10 to 13) whose neighbour above and below is also a plain track cell,
//      and a P3 probe that falls on a grid line is moved 1 px away from the
//      disc and named in the failure text.
//   2. P4 puts the token of tokenIndex 1 on its finished cell, the middle of
//      its triangle's base. The probe 0.55 d below the centre is checked to be
//      at least 3 px inside the seat's triangle (clear of the divider lines,
//      which are the triangle's edges); if it is not, the side point 0.55 d to
//      the left or right is used, and the case says so.
//   3. The triangle's own colour is the seat colour at alpha 1.0 over dieFace
//      (all four seats are in play), computed from LudoColors.

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
const double _shadowGap = 0.02;
const double _finishedGap = 0.03;

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

/// A seat's finished token: tokenIndex 1, the middle of the triangle's base.
List<_Placed> _finishedPlacements(int quarters) => <_Placed>[
  for (final int seat in _allSeats)
    _Placed(
      seat,
      1,
      57,
      toView(cellFor(seat: seat, progress: 57, tokenIndex: 1), quarters),
    ),
];

/// The three corners, in board-local px, of [seat]'s centre triangle in the
/// view: the base on the side of the centre block that its progress-56 cell
/// touches, the apex at the board centre.
List<Offset> _triangle(int seat, int quarters) {
  const double near = 6 * _cell;
  const double far = 9 * _cell;
  const Offset middle = Offset(7.5 * _cell, 7.5 * _cell);
  final BoardCell last = toView(cellFor(seat: seat, progress: 56), quarters);
  final int dx = last.col - 7;
  final int dy = last.row - 7;
  if (dx.abs() > dy.abs()) {
    final double x = dx < 0 ? near : far;
    return <Offset>[Offset(x, near), Offset(x, far), middle];
  }
  final double y = dy < 0 ? near : far;
  return <Offset>[Offset(near, y), Offset(far, y), middle];
}

/// Distance in px from [p] to the nearest edge of the triangle, negative when
/// [p] is outside it.
double _insideMargin(Offset p, List<Offset> t) {
  double signed(Offset a, Offset b) =>
      (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
  final double s0 = signed(t[0], t[1]);
  final double s1 = signed(t[1], t[2]);
  final double s2 = signed(t[2], t[0]);
  final bool inside =
      (s0 >= 0 && s1 >= 0 && s2 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0);
  double edge(Offset a, Offset b) {
    final Offset ab = b - a;
    final double len = ab.distance;
    return ((b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx))
            .abs() /
        len;
  }

  final double m = math.min(
    edge(t[0], t[1]),
    math.min(edge(t[1], t[2]), edge(t[2], t[0])),
  );
  return inside ? m : -m;
}

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

    // P3: contact shadow. The point 0.55 d under the centre (just below the
    // disc's bottom edge) is darker than the point 0.55 d over the centre
    // (just above its top edge) by at least 0.02 relative luminance.
    testWidgets('P3 contact shadow on the track, $view', (tester) async {
      final String name = 'P3 contact shadow on the track, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _plainTrackPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        Offset under = r.center + Offset(0, 0.55 * d);
        Offset over = r.center - Offset(0, 0.55 * d);
        final List<String> moved = <String>[];
        // Move a probe that lands on a grid line by 1 px away from the disc.
        if (_onGridLine(over.dy.floor())) {
          moved.add(
            'above probe ${_px(over)} was on the grid line at pixel row '
            '${over.dy.floor()}, moved 1 px up',
          );
          over = over - const Offset(0, 1);
        }
        if (_onGridLine(under.dy.floor())) {
          moved.add(
            'below probe ${_px(under)} was on the grid line at pixel row '
            '${under.dy.floor()}, moved 1 px down',
          );
          under = under + const Offset(0, 1);
        }
        if (_onGridLine(over.dy.floor()) ||
            _onGridLine(under.dy.floor()) ||
            _onGridLine(over.dx.floor())) {
          fail(
            'C-641t harness: ${p.label}: a P3 probe is still on a grid line '
            'after a 1 px move (above ${_px(over)}, below ${_px(under)}). '
            'Scenario: ${s.scenario}',
          );
        }
        final pu = s.frame.at(under);
        final po = s.frame.at(over);
        final double gap = po.rgb.luminance - pu.rgb.luminance;
        if (gap < _shadowGap) {
          s.misses.add(
            '${p.label}, P3 below the disc ${_px(under)} = px (${pu.x}, '
            '${pu.y}) ${pu.rgb.hex} luminance ${_lum(pu.rgb)}; above the disc '
            '${_px(over)} = px (${po.x}, ${po.y}) ${po.rgb.hex} luminance '
            '${_lum(po.rgb)}: expected below darker than above by at least '
            '$_shadowGap, read ${gap.toStringAsFixed(3)} '
            '(d ${d.toStringAsFixed(2)} px)'
            '${moved.isEmpty ? '' : '; ${moved.join('; ')}'}',
          );
        }
      }
      s.done();
    });

    // P4: a finished piece on its own triangle. The point 0.55 d below the
    // centre differs from the triangle's own colour by relative luminance at
    // least 0.03. If that point is not inside the triangle, the side point
    // 0.55 d left or right is used, whichever stays inside.
    testWidgets('P4 finished piece on its triangle, $view', (tester) async {
      final String name = 'P4 finished piece on its triangle, $view';
      final _Scene s = await _render(
        tester,
        caseName: name,
        mySeat: mySeat,
        placed: _finishedPlacements(q),
      );
      for (final _Placed p in s.placed) {
        final Rect r = s.discs[p]!;
        final double d = r.width;
        final List<Offset> tri = _triangle(p.seat, q);
        final _Rgb ground = _Rgb.of(LudoColors.seats[p.seat]);
        // Opaque seat colour over dieFace is the seat colour itself.
        Offset at = r.center + Offset(0, 0.55 * d);
        String which = '0.55 d below the centre';
        if (_insideMargin(at, tri) < 3) {
          final Offset left = r.center - Offset(0.55 * d, 0);
          final Offset right = r.center + Offset(0.55 * d, 0);
          final Offset? side = _insideMargin(left, tri) >= 3
              ? left
              : _insideMargin(right, tri) >= 3
              ? right
              : null;
          if (side == null) {
            fail(
              'C-641t harness: ${p.label}: neither the point below ${_px(at)} '
              'nor the side points ${_px(left)} and ${_px(right)} lie 3 px '
              'inside the seat triangle ${tri.map(_px).join(', ')}. '
              'Scenario: ${s.scenario}',
            );
          }
          at = side;
          which = side == left
              ? '0.55 d left of the centre (the point below left the triangle)'
              : '0.55 d right of the centre (the point below left the '
                    'triangle)';
        }
        final px = s.frame.at(at);
        final double gap = (px.rgb.luminance - ground.luminance).abs();
        if (gap < _finishedGap) {
          s.misses.add(
            '${p.label}, P4 $which ${_px(at)} = px (${px.x}, ${px.y}) '
            '${px.rgb.hex} luminance ${_lum(px.rgb)}; triangle colour '
            '${ground.hex} luminance ${_lum(ground)}: expected a difference '
            'of at least $_finishedGap, read ${gap.toStringAsFixed(3)} '
            '(d ${d.toStringAsFixed(2)} px, triangle '
            '${tri.map(_px).join(' ')})',
          );
        }
      }
      s.done();
    });
  }
}
