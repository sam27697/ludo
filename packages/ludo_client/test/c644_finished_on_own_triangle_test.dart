// Proof of order 644 (work/ludo/orders/644-finished-pieces-on-own-triangle.md),
// decisions D1, D3 and D4, written from that contract's text alone.
//
// Method. LudoBoard is mounted in a 450 x 450 physical viewport at device
// pixel ratio 1.0, so one cell (c) is 30 px, inside one RepaintBoundary that
// is rendered with toImage(pixelRatio: 1.0) and read as rawStraightRgba. The
// harness is copied from test/c639_board_art_test.dart, not imported. No
// seatNames, turnSeat or seatDice are passed, so no chip, glow or die sits
// over a probe point.
//
// A finished token's drawn disc is read from the rect of the widget keyed
// token-<seat>-<index> (a Semantics around the DecoratedBox circle, placed at
// the drawn size), in board-local px. One case checks that this rect is
// square, so its half width is the disc radius used everywhere below.
//
// Each seat's triangle is derived here from D1, using only the public
// geometry (cellFor at progress 56, toView, viewQuarters) and the numbers of
// the contract: the base is the side of the centre block [6c, 9c] that the
// view cell of progress 56 touches, the apex is (7.5c, 7.5c), `a` is the base
// end with the smaller coordinate along the base. In the triangle's frame u
// runs from a towards b along the base and v from the base towards the apex.
// The four spots are D3's. Nothing is imported or called from board.dart
// beyond LudoBoard itself.
//
// Every case runs for mySeat null, 0, 1, 2 and 3 (the board rotates), and
// collects all its misses into one failure that names the seat, the token,
// the view, the numbers, and the scenario to re-run. The scenes are fixed, so
// the scenario text is the whole reproduction: there is no random seed.
//
// Reading choices, reported rather than invented around:
//
//   1. T4 names its probe directions "towards the apex", "along the base both
//      ways" and "away from the apex". They are read as the unit vector from
//      the disc centre to the apex point, the unit vector along the base in
//      each sense, and the reverse of the first. Away from the apex lands
//      below the base for every spot on the lower row, so T4 drops it there
//      by its own keep rule.
//   2. T4's "inside the own triangle by at least 2 px" is the smallest of
//      the point's distances to the three edges, measured perpendicular to
//      each edge.
//   3. T4 "closer" is strictly closer: a tie with another seat colour fails.
//   4. T1 and T2 use the contract's 0.5 px slack on the radius arithmetic.
//
// C-659t return 1. X190 (work/ludo/orders/659-centre-by-seats.md, R1 to R3)
// replaces the four fixed spots of D3: a seat's finished pieces now form one
// stack that overlaps by design. T2, T3, T4 and T6 are rewritten for X190, each
// marked at its case. With four seats the region of a seat is still its
// triangle (R1), so the triangle frame below stays the reference; with two
// opposite seats it is the half block on the seat's side. Which finished token
// is first in a stack is not specified, so a stack is ordered by distance from
// the seat's base side, never by token index.

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

/// D3: the disc diameter, in cells.
const double _diameterCells = 0.55;

/// D3: the four spots in the triangle's frame, in cells, by token index.
const List<({double u, double v})> _spots = <({double u, double v})>[
  (u: 0.86, v: 0.31),
  (u: 1.50, v: 0.31),
  (u: 2.14, v: 0.31),
  (u: 1.50, v: 0.95),
];

const List<int> _allSeats = <int>[0, 1, 2, 3];
const List<int?> _views = <int?>[null, 0, 1, 2, 3];

String _viewName(int? mySeat) => 'mySeat ${mySeat ?? 'null'}';

// ---------------------------------------------------------------------------
// Harness (copied from test/c639_board_art_test.dart).
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

class _Frame {
  _Frame(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  /// The pixel that contains board-local [local] (x and y in logical px).
  ({double r, double g, double b, int x, int y}) at(Offset local) {
    final int x = local.dx.floor().clamp(0, width - 1);
    final int y = local.dy.floor().clamp(0, height - 1);
    final int i = (y * width + x) * 4;
    return (
      r: data.getUint8(i).toDouble(),
      g: data.getUint8(i + 1).toDouble(),
      b: data.getUint8(i + 2).toDouble(),
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
// D1: a seat's triangle, from the public geometry and the contract's numbers.
// ---------------------------------------------------------------------------

class _Triangle {
  _Triangle(this.seat, this.side, this.a, this.eu, this.ev);

  final int seat;

  /// The side of the centre block the base lies on: left, right, top, bottom.
  final String side;

  /// The base end with the smaller coordinate along the base, board px.
  final Offset a;

  /// Unit vector along the base from a towards b.
  final Offset eu;

  /// Unit vector from the base towards the apex.
  final Offset ev;

  static const double baseLength = 3 * _cell;

  Offset get b => a + eu * baseLength;
  Offset get apex => const Offset(7.5 * _cell, 7.5 * _cell);

  /// The point at ([u], [v]) cells in the triangle's frame, board px.
  Offset at(double u, double v) => a + eu * (u * _cell) + ev * (v * _cell);

  /// [p]'s distance in px from the base line, positive towards the apex.
  double baseDistance(Offset p) => (p - a).dx * ev.dx + (p - a).dy * ev.dy;

  double _u(Offset p) => (p - a).dx * eu.dx + (p - a).dy * eu.dy;

  /// [p]'s distance in px from the a-apex edge, positive inside.
  double edgeADistance(Offset p) => (_u(p) - baseDistance(p)) / math.sqrt2;

  /// [p]'s distance in px from the b-apex edge, positive inside.
  double edgeBDistance(Offset p) =>
      (baseLength - _u(p) - baseDistance(p)) / math.sqrt2;

  /// The smallest of the three signed edge distances, positive inside.
  double inside(Offset p) =>
      math.min(baseDistance(p), math.min(edgeADistance(p), edgeBDistance(p)));
}

_Triangle _triangleFor(int seat, int quarters) {
  final BoardCell out = toView(cellFor(seat: seat, progress: 56), quarters);
  final bool inBand;
  if (out.col == 5 || out.col == 9) {
    inBand = out.row >= 6 && out.row <= 8;
  } else if (out.row == 5 || out.row == 9) {
    inBand = out.col >= 6 && out.col <= 8;
  } else {
    inBand = false;
  }
  if (!inBand) {
    fail(
      'C-644t harness: seat $seat progress 56 maps to view cell $out at '
      'quarters $quarters, which does not touch a side of the centre block',
    );
  }
  if (out.col == 5) {
    return _Triangle(
      seat,
      'left',
      const Offset(6 * _cell, 6 * _cell),
      const Offset(0, 1),
      const Offset(1, 0),
    );
  }
  if (out.col == 9) {
    return _Triangle(
      seat,
      'right',
      const Offset(9 * _cell, 6 * _cell),
      const Offset(0, 1),
      const Offset(-1, 0),
    );
  }
  if (out.row == 5) {
    return _Triangle(
      seat,
      'top',
      const Offset(6 * _cell, 6 * _cell),
      const Offset(1, 0),
      const Offset(0, 1),
    );
  }
  return _Triangle(
    seat,
    'bottom',
    const Offset(6 * _cell, 9 * _cell),
    const Offset(1, 0),
    const Offset(0, -1),
  );
}

// ---------------------------------------------------------------------------
// A rendered scene: the discs that are finished, and the frame.
// ---------------------------------------------------------------------------

class _Disc {
  _Disc({
    required this.seat,
    required this.index,
    required this.rect,
    required this.triangle,
  });

  final int seat;
  final int index;
  final Rect rect;
  final _Triangle triangle;

  Offset get centre => rect.center;
  double get radius => rect.width / 2;
  String get label => 'seat $seat token $index';
  String get at =>
      'centre (${centre.dx.toStringAsFixed(2)}, '
      '${centre.dy.toStringAsFixed(2)}) px, drawn box '
      '${rect.width.toStringAsFixed(2)} x ${rect.height.toStringAsFixed(2)} px';
}

class _Scene {
  _Scene({
    required this.name,
    required this.scenario,
    required this.mySeat,
    required this.discs,
    required this.frame,
    this.badges = const <Rect>[],
  });

  final List<Rect> badges;
  final String name;
  final String scenario;
  final int? mySeat;
  final List<_Disc> discs;
  final _Frame frame;

  String get view => _viewName(mySeat);

  void failWith(String caseName, List<String> misses) {
    if (misses.isEmpty) {
      return;
    }
    fail(
      'C-644t $caseName ($name, $view): ${misses.length} miss(es).\n'
      '${misses.map((String m) => '  - $m').join('\n')}\n'
      'Scenario: $scenario. Reproduce: cd packages/ludo_client && '
      'flutter test test/c644_finished_on_own_triangle_test.dart '
      "--plain-name '$name, $view'",
    );
  }
}

/// Mounts a board with [tokens] (progress per seat, in token index order) and
/// reads every token whose progress is 57.
Future<_Scene> _mount(
  WidgetTester tester, {
  required String name,
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  required int? mySeat,
}) async {
  _pinViewportToBoard(tester);
  await tester.pumpWidget(
    _pixelHarness(tokens: tokens, seatsInPlay: seatsInPlay, mySeat: mySeat),
  );
  await tester.pump();
  final Offset origin = tester.getTopLeft(find.byType(LudoBoard));
  final int q = viewQuarters(mySeat);
  final List<_Disc> discs = <_Disc>[];
  for (final int seat in seatsInPlay) {
    final _Triangle tri = _triangleFor(seat, q);
    for (int index = 0; index < 4; index++) {
      if (tokens[seat]![index] != 57) {
        continue;
      }
      final Finder token = find.byKey(Key('token-$seat-$index'));
      expect(
        token.evaluate().length,
        1,
        reason:
            'C-644t harness: expected exactly one token-$seat-$index widget '
            '($name, ${_viewName(mySeat)})',
      );
      discs.add(
        _Disc(
          seat: seat,
          index: index,
          rect: tester.getRect(token).shift(-origin),
          triangle: tri,
        ),
      );
    }
  }
  final List<Rect> badges = <Rect>[
    for (final int seat in _allSeats)
      if (find.byKey(Key('board-finished-count-$seat')).evaluate().isNotEmpty)
        tester
            .getRect(find.byKey(Key('board-finished-count-$seat')).first)
            .shift(-origin),
  ];
  final _Frame frame = await _capture(tester);
  return _Scene(
    badges: badges,
    name: name,
    scenario:
        'LudoBoard 450x450 dpr 1.0, seatsInPlay $seatsInPlay, '
        '${_viewName(mySeat)}, tokens $tokens, no seatNames/turnSeat/'
        'seatDice',
    mySeat: mySeat,
    discs: discs,
    frame: frame,
  );
}

Map<int, List<int>> _allFinished(List<int> seats) => <int, List<int>>{
  for (final int seat in seats) seat: <int>[57, 57, 57, 57],
};

Map<int, List<int>> _noneFinished(List<int> seats) => <int, List<int>>{
  for (final int seat in seats) seat: <int>[-1, -1, -1, -1],
};

/// Only token index 3 of every seat is finished, the rest sit in the yard.
Map<int, List<int>> _lastOnly(List<int> seats) => <int, List<int>>{
  for (final int seat in seats) seat: <int>[-1, -1, -1, 57],
};

// ---------------------------------------------------------------------------
// The checks, each returning its misses.
// ---------------------------------------------------------------------------

String _px(double v) => v.toStringAsFixed(2);

/// T1: wholly inside the own triangle.
List<String> _insideOwnTriangle(_Scene scene) {
  final List<String> misses = <String>[];
  for (final _Disc d in scene.discs) {
    final _Triangle t = d.triangle;
    final Offset c = d.centre;
    final double slack = d.radius - 0.5;
    final Map<String, double> edges = <String, double>{
      'base (${t.side} side)': t.baseDistance(c),
      'edge a-apex': t.edgeADistance(c),
      'edge b-apex': t.edgeBDistance(c),
    };
    final bool centreIn = t.inside(c) >= 0;
    final List<String> bad = <String>[
      if (!centreIn) 'centre is outside the triangle',
      for (final MapEntry<String, double> e in edges.entries)
        if (e.value < slack)
          '${e.key} distance ${_px(e.value)} px < radius ${_px(d.radius)} '
              'minus 0.5 = ${_px(slack)} px',
    ];
    if (bad.isNotEmpty) {
      misses.add(
        '${d.label}: expected the disc wholly inside seat ${d.seat}\'s '
        '${t.side}-side triangle (a ${t.a}, apex ${t.apex}); ${d.at}; '
        '${bad.join('; ')}',
      );
    }
  }
  return misses;
}

/// T2: no two discs overlap.
List<String> _noOverlap(_Scene scene) {
  final List<String> misses = <String>[];
  for (int i = 0; i < scene.discs.length; i++) {
    for (int j = i + 1; j < scene.discs.length; j++) {
      final _Disc p = scene.discs[i];
      final _Disc q = scene.discs[j];
      final double dist = (p.centre - q.centre).distance;
      final double need = p.radius + q.radius - 0.5;
      if (dist < need) {
        misses.add(
          '${p.label} and ${q.label}: expected centres at least ${_px(need)} '
          'px apart (radii ${_px(p.radius)} + ${_px(q.radius)} minus 0.5), '
          'read ${_px(dist)} px; ${p.label} ${p.at}; ${q.label} ${q.at}',
        );
      }
    }
  }
  return misses;
}

/// X190 (T2): inside one stack each disc's edge stays visible (consecutive
/// centres at least 0.18 x diameter apart); discs of different seats never
/// overlap.
List<String> _edgesVisibleSeatsApart(_Scene scene) {
  final List<String> misses = <String>[];
  for (final MapEntry<int, List<_Disc>> e in _stacks(scene).entries) {
    final List<_Disc> stack = e.value;
    for (int k = 1; k < stack.length; k++) {
      final double step = (stack[k].centre - stack[k - 1].centre).distance;
      final double need = 0.18 * stack[k].rect.width;
      if (step < need - 0.01) {
        misses.add(
          'seat ${e.key}: expected consecutive discs of the stack at least '
          '0.18 x diameter = ${_px(need)} px apart so every edge shows, read '
          '${_px(step)} px between ${stack[k - 1].label} ${stack[k - 1].at} '
          'and ${stack[k].label} ${stack[k].at}',
        );
      }
    }
  }
  for (int i = 0; i < scene.discs.length; i++) {
    for (int j = i + 1; j < scene.discs.length; j++) {
      final _Disc p = scene.discs[i];
      final _Disc q = scene.discs[j];
      if (p.seat == q.seat) {
        continue;
      }
      final double dist = (p.centre - q.centre).distance;
      final double need = p.radius + q.radius - 0.5;
      if (dist < need) {
        misses.add(
          '${p.label} and ${q.label}: discs of different seats must not '
          'overlap, expected centres at least ${_px(need)} px apart (radii '
          '${_px(p.radius)} + ${_px(q.radius)} minus 0.5), read '
          '${_px(dist)} px; ${p.label} ${p.at}; ${q.label} ${q.at}',
        );
      }
    }
  }
  return misses;
}

/// X190 (T6): two opposite seats, each region is the half block on its side:
/// 3 cells along the base, 1.5 cells deep. The disc's full radius is inside.
List<String> _insideOwnHalf(_Scene scene) {
  final List<String> misses = <String>[];
  for (final _Disc d in scene.discs) {
    final _Triangle t = d.triangle;
    final Offset c = d.centre;
    final double depth = t.baseDistance(c);
    final double along = t._u(c);
    const double halfDepth = 1.5 * _cell;
    final List<String> bad = <String>[
      if (depth < d.radius - 0.01)
        'depth ${_px(depth)} px from the ${t.side} side < radius '
            '${_px(d.radius)}',
      if (halfDepth - depth < d.radius - 0.01)
        'only ${_px(halfDepth - depth)} px from the half\'s inner edge '
            '(the boundary through the centre) < radius ${_px(d.radius)}',
      if (along < d.radius - 0.01 ||
          _Triangle.baseLength - along < d.radius - 0.01)
        'position ${_px(along)} px along the side, expected the radius '
            '${_px(d.radius)} clear of both ends of the ${_px(_Triangle.baseLength)} px side',
    ];
    if (bad.isNotEmpty) {
      misses.add(
        '${d.label}: expected the disc wholly inside seat ${d.seat}\'s half '
        'of the block (${t.side} side, 3 x 1.5 cells); ${d.at}; '
        '${bad.join('; ')}',
      );
    }
  }
  return misses;
}

/// A seat's discs ordered from its base side inwards, never by token index.
List<_Disc> _stackOrder(List<_Disc> discs) => List<_Disc>.of(discs)
  ..sort(
    (_Disc a, _Disc b) => a.triangle
        .baseDistance(a.centre)
        .compareTo(b.triangle.baseDistance(b.centre)),
  );

Map<int, List<_Disc>> _stacks(_Scene scene) => <int, List<_Disc>>{
  for (final int seat in _allSeats)
    if (scene.discs.any((_Disc d) => d.seat == seat))
      seat: _stackOrder(<_Disc>[
        for (final _Disc d in scene.discs)
          if (d.seat == seat) d,
      ]),
};

/// X190 R3 (T3): diameter 0.55 c, the disc's full radius inside the seat's
/// triangle (the four-seat region), and one stack: every step the same
/// vector, pointing from the base side towards the centre.
List<String> _sizeAndStack(_Scene scene) {
  final List<String> misses = <String>[];
  const double wantD = _diameterCells * _cell;
  for (final _Disc d in scene.discs) {
    final _Triangle t = d.triangle;
    final List<String> bad = <String>[
      if ((d.rect.width - wantD).abs() > 0.5)
        'width ${_px(d.rect.width)} px, expected ${_px(wantD)} px '
            '(0.55 c) within 0.5',
      if ((d.rect.height - wantD).abs() > 0.5)
        'height ${_px(d.rect.height)} px, expected ${_px(wantD)} px '
            '(0.55 c) within 0.5',
      if (t.inside(d.centre) < d.radius - 0.01)
        'expected the full radius ${_px(d.radius)} px clear of every edge of '
            'the ${t.side}-side triangle (a ${t.a}, apex ${t.apex}), the '
            'nearest edge is ${_px(t.inside(d.centre))} px away',
    ];
    if (bad.isNotEmpty) {
      misses.add('${d.label}: ${d.at}; ${bad.join('; ')}');
    }
  }
  for (final MapEntry<int, List<_Disc>> e in _stacks(scene).entries) {
    final List<_Disc> stack = e.value;
    if (stack.length < 2) {
      continue;
    }
    final _Triangle t = stack.first.triangle;
    final Offset first = stack.first.centre;
    final Offset v0 = stack[1].centre - first;
    final String centres = stack
        .map((_Disc d) => '(${_px(d.centre.dx)}, ${_px(d.centre.dy)})')
        .join(' ');
    for (int k = 1; k < stack.length; k++) {
      final Offset v = stack[k].centre - stack[k - 1].centre;
      if ((v - v0).distance > 0.01) {
        misses.add(
          'seat ${e.key}: expected every step of the stack to be the same '
          'vector, step 1 is (${_px(v0.dx)}, ${_px(v0.dy)}), step $k is '
          '(${_px(v.dx)}, ${_px(v.dy)}); centres $centres',
        );
      }
      final double inward = v.dx * t.ev.dx + v.dy * t.ev.dy;
      final Offset toApex = t.apex - first;
      if (inward <= 0 || v.dx * toApex.dx + v.dy * toApex.dy <= 0) {
        misses.add(
          'seat ${e.key}: expected step $k to run from the ${t.side} base '
          'side towards the centre ${t.apex}, step is (${_px(v.dx)}, '
          '${_px(v.dy)}), component away from the base ${_px(inward)} px; '
          'centres $centres',
        );
      }
    }
  }
  return misses;
}

int _colourDistance(
  ({double r, double g, double b, int x, int y}) px,
  Color c,
) =>
    ((px.r - c.r * 255).abs() +
            (px.g - c.g * 255).abs() +
            (px.b - c.b * 255).abs())
        .round();

String _hex(({double r, double g, double b, int x, int y}) px) {
  String two(double v) =>
      v.round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(px.r)}${two(px.g)}${two(px.b)}';
}

/// X190 (T4): points of each seat's region that no disc and no count badge
/// covers read the own seat's colour. The points are a 0.5 c grid in the
/// triangle's frame, kept when 2 px inside the triangle, more than radius + 2
/// px from every disc of every seat, and outside every badge grown by 2 px.
List<String> _colourInRegion(_Scene scene) {
  final List<String> misses = <String>[];
  for (final int seat in _allSeats) {
    if (!scene.discs.any((_Disc d) => d.seat == seat)) {
      continue;
    }
    final _Triangle t = scene.discs
        .firstWhere((_Disc d) => d.seat == seat)
        .triangle;
    int kept = 0;
    for (double u = 0.25; u < 3; u += 0.5) {
      for (double v = 0.25; v < 1.5; v += 0.5) {
        final Offset p = t.at(u, v);
        if (t.inside(p) < 2) {
          continue;
        }
        if (scene.discs.any(
          (_Disc d) => (d.centre - p).distance <= d.radius + 2,
        )) {
          continue;
        }
        if (scene.badges.any((Rect b) => b.inflate(2).contains(p))) {
          continue;
        }
        kept++;
        final px = scene.frame.at(p);
        final int own = _colourDistance(px, LudoColors.seats[seat]);
        for (final int other in _allSeats) {
          if (other == seat) {
            continue;
          }
          final int dist = _colourDistance(px, LudoColors.seats[other]);
          if (dist <= own) {
            misses.add(
              'seat $seat: probe at u $u, v $v cells = (${_px(p.dx)}, '
              '${_px(p.dy)}) px = pixel (${px.x}, ${px.y}) reads ${_hex(px)}, '
              'expected closer to seat $seat colour (distance $own) than to '
              'seat $other colour (distance $dist)',
            );
          }
        }
      }
    }
    if (kept < 3) {
      misses.add(
        'seat $seat: expected at least 3 probe points of the ${t.side}-side '
        'triangle covered by no disc and no badge, kept $kept',
      );
    }
  }
  return misses;
}

// ---------------------------------------------------------------------------
// The cases.
// ---------------------------------------------------------------------------

void main() {
  // The contract's own arithmetic, in the triangle frame and in cells: base 3,
  // apex at (1.5, 1.5), so the sides are v = u and v = 3 - u. Run first so a
  // wrong number in D3 shows up here and not as a failing board.
  test('D3 arithmetic: the four spots fit the triangle and each other', () {
    const double r = _diameterCells / 2;
    final List<String> misses = <String>[];
    for (int i = 0; i < 4; i++) {
      final double u = _spots[i].u;
      final double v = _spots[i].v;
      final Map<String, double> edges = <String, double>{
        'base': v,
        'edge a-apex': (u - v) / math.sqrt2,
        'edge b-apex': (3 - u - v) / math.sqrt2,
      };
      for (final MapEntry<String, double> e in edges.entries) {
        if (e.value < r) {
          misses.add(
            'spot $i (u $u, v $v): ${e.key} distance ${e.value.toStringAsFixed(3)} '
            'cells < radius $r cells',
          );
        }
      }
      for (int j = i + 1; j < 4; j++) {
        final double dist = math.sqrt(
          math.pow(u - _spots[j].u, 2) + math.pow(v - _spots[j].v, 2),
        );
        if (dist < 2 * r) {
          misses.add(
            'spots $i and $j: centres ${dist.toStringAsFixed(3)} cells apart '
            '< ${2 * r} (two radii)',
          );
        }
      }
    }
    expect(
      misses,
      isEmpty,
      reason: 'C-644t D3 arithmetic does not hold:\n${misses.join('\n')}',
    );
  });

  test('D1 derivation: each seat has its own side of the centre block', () {
    for (final int? mySeat in _views) {
      final int q = viewQuarters(mySeat);
      final Set<String> sides = <String>{
        for (final int seat in _allSeats) _triangleFor(seat, q).side,
      };
      expect(
        sides.length,
        4,
        reason:
            'C-644t harness: four seats must use four different sides of the '
            'centre block in ${_viewName(mySeat)}, got $sides',
      );
    }
  });

  for (final int? mySeat in _views) {
    final String view = _viewName(mySeat);

    // Harness check, no finished token on the board: the triangle derived
    // from D1 is the one the board paints, so every D3 spot reads the own
    // seat colour. A pass here means a later T4 miss is not a wrong triangle.
    testWidgets('T00 derived triangle is the painted one, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T00 derived triangle is the painted one',
        tokens: _noneFinished(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      final int q = viewQuarters(mySeat);
      final List<String> misses = <String>[];
      for (final int seat in _allSeats) {
        final _Triangle t = _triangleFor(seat, q);
        for (int i = 0; i < 4; i++) {
          final Offset p = t.at(_spots[i].u, _spots[i].v);
          final px = scene.frame.at(p);
          final int own = _colourDistance(px, LudoColors.seats[seat]);
          for (final int other in _allSeats) {
            if (other != seat &&
                _colourDistance(px, LudoColors.seats[other]) <= own) {
              misses.add(
                'seat $seat spot $i at (${_px(p.dx)}, ${_px(p.dy)}) px reads '
                '${_hex(px)}, expected closer to seat $seat colour than to '
                'seat $other colour',
              );
            }
          }
        }
      }
      scene.failWith('T00', misses);
    });

    testWidgets('T0 token box is the drawn disc, square, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T0 token box is the drawn disc, square',
        tokens: _allFinished(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      expect(
        scene.discs.length,
        16,
        reason:
            'C-644t T0 (${scene.view}): expected 16 finished token widgets, '
            'found ${scene.discs.length}. Scenario: ${scene.scenario}',
      );
      scene.failWith('T0', <String>[
        for (final _Disc d in scene.discs)
          if ((d.rect.width - d.rect.height).abs() > 0.01)
            '${d.label}: drawn box ${_px(d.rect.width)} x '
                '${_px(d.rect.height)} px is not square, so its half width '
                'is not a disc radius',
      ]);
    });

    testWidgets('T1 inside own triangle, 4 seats all finished, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T1 inside own triangle, 4 seats all finished',
        tokens: _allFinished(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      scene.failWith('T1', _insideOwnTriangle(scene));
    });

    // X190 replaces D3 here: one seat's discs overlap by design.
    testWidgets(
      'T2 stack edges visible and seats apart, 4 seats all finished, $view',
      (tester) async {
        final _Scene scene = await _mount(
          tester,
          name: 'T2 stack edges visible and seats apart, 4 seats all finished',
          tokens: _allFinished(_allSeats),
          seatsInPlay: _allSeats,
          mySeat: mySeat,
        );
        scene.failWith('T2', _edgesVisibleSeatsApart(scene));
      },
    );

    // X190 replaces D3 here: a stack stepping inward, not four fixed spots.
    testWidgets('T3 size and stack, 4 seats all finished, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T3 size and stack, 4 seats all finished',
        tokens: _allFinished(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      scene.failWith('T3', _sizeAndStack(scene));
    });

    // X190 replaces D3 here: probe the region's free points, not around a spot.
    testWidgets('T4 the colour of the region, 4 seats all finished, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T4 the colour of the region, 4 seats all finished',
        tokens: _allFinished(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      scene.failWith('T4', _colourInRegion(scene));
    });

    testWidgets('T5 partial centre, only token 3 finished, $view', (
      tester,
    ) async {
      final _Scene scene = await _mount(
        tester,
        name: 'T5 partial centre, only token 3 finished',
        tokens: _lastOnly(_allSeats),
        seatsInPlay: _allSeats,
        mySeat: mySeat,
      );
      expect(
        scene.discs.length,
        4,
        reason:
            'C-644t T5 (${scene.view}): expected 4 finished token widgets '
            '(index 3 of each seat), found ${scene.discs.length}. Scenario: '
            '${scene.scenario}',
      );
      scene.failWith('T5', <String>[
        ..._insideOwnTriangle(scene).map((String m) => 'T1: $m'),
        ..._noOverlap(scene).map((String m) => 'T2: $m'),
      ]);
    });
  }

  // X190 replaces X187 here: the half block is each seat's region, stacks overlap.
  testWidgets('T6 two seats in play, all finished, mySeat 0', (tester) async {
    final _Scene scene = await _mount(
      tester,
      name: 'T6 two seats in play, all finished',
      tokens: _allFinished(const <int>[0, 2]),
      seatsInPlay: const <int>[0, 2],
      mySeat: 0,
    );
    expect(
      scene.discs.length,
      8,
      reason:
          'C-644t T6 (${scene.view}): expected 8 finished token widgets, '
          'found ${scene.discs.length}. Scenario: ${scene.scenario}',
    );
    scene.failWith('T6', <String>[
      ..._insideOwnHalf(scene).map((String m) => 'T1: $m'),
      ..._edgesVisibleSeatsApart(scene).map((String m) => 'T2: $m'),
    ]);
  });
}
