// Proof of order 659 (work/ludo/orders/659-centre-by-seats.md), contract
// R1 to R4, written from that contract's text alone.
//
// What is proven.
//   R1/R2  `centreRegions` divides the 3 x 3 centre block into one convex
//          clockwise polygon per seat in play, by the angular rule of R1.
//          Pure cases, every seat set of size 1 to 4 (all 15 subsets), at
//          quarters 0 to 3 and two cell sizes.
//   R3     A seat's finished pieces form one stack in its region: first at the
//          base point, the rest offset by one vector of at least 0.18 x the
//          disc diameter, from the base side towards the centre, full radius
//          clear of the region's edges. Widget cases on a real LudoBoard.
//   R4     The count badge, key board-finished-count-<seat>.
//   R2     The painter fills each region in its seat's colour (pixel probe).
//
// Independence. The expected regions are built here from the contract's own
// words: the entry side of a seat from cellFor/toView at progress 56, the
// angular partition of R1 computed with a half-plane clip, and hand-made
// shapes (triangles, rectangles, quadrilaterals) for the named consequences.
// Nothing is read from board.dart except LudoBoard, centreRegions and the
// public geometry.
//
// Reading choices and ambiguities, reported rather than invented around:
//
//   1. Disc positions are read from the rect of the widget keyed
//      token-<seat>-<index> (the box of the drawn disc; a case checks it is
//      0.55 x cell square), in board-local px, board mounted at 450 x 450
//      logical, dpr 1.0, so a cell is 30 px. Same method as
//      test/c644_finished_on_own_triangle_test.dart.
//   2. R3 says "the first" of the stack. Which finished token is first is not
//      specified, so the stack is ordered here by distance from the seat's
//      base side, not by token index, and the position SET of a seat with k
//      finished pieces must be the same whichever token indices are home.
//   3. "Clear of its edges" is read with 0.01 px of slack, no more.
//   4. "From the region's base side towards the centre" is read as: the
//      offset vector has a positive component away from the seat's own side
//      of the block, and a positive component towards the block centre.
//   5. The badge, "beside the stack", is read as: the badge circle lies in
//      the region with its full radius clear of the edges, and does not
//      cover the centre of any disc of that seat.
//   6. The numeral is compared as the plain digits N.toString() in both
//      languages, as the place medal does (place.toString()). A localised
//      digit would fail here; the contract says "the number N".
//   7. "Same digit style as the place medals" is read as font family, family
//      fallbacks, weight w800 and line height 1. Size is the badge's own.
//   8. "White" is read as a colour whose channels are all at least 0.93, so
//      the existing near-white ink also counts.
//   9. "The seat's colour darkened" is read as: opaque, darker than the seat
//      colour, hue within 25 degrees of it.
//  10. "The text's painted size inside the badge's" is read from the glyph
//      line boxes of the badge's paragraph, transformed to the screen, which
//      must lie inside the badge rect. The corners of that box are not
//      required to lie inside the inscribed circle.
//  11. Unspecified and therefore not tested: an empty seat list, a repeated
//      or out-of-range seat, quarters outside 0..3.
//  12. The old painter draws absent seats faded; R2 says nothing is painted
//      for them. The pixel probe expects the owning seat's colour in every
//      region, which a faded absent triangle cannot give.
//
// Every failure names the scenario and the test to re-run. The scenes are
// fixed, so there is no random seed: the scenario text is the whole
// reproduction.

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

const String _testFile = 'test/c659_centre_regions_test.dart';
const List<double> _cellSizes = <double>[30.0, 17.3];

typedef Poly = List<Offset>;

// ---------------------------------------------------------------------------
// Failure plumbing
// ---------------------------------------------------------------------------

void _failWith(String name, String scenario, List<String> misses) {
  if (misses.isEmpty) {
    return;
  }
  fail(
    'C-659t $name ($scenario): ${misses.length} miss(es).\n'
    '${misses.map((String m) => '  - $m').join('\n')}\n'
    'Scenario: $scenario (fixed, no random seed). Reproduce: cd '
    "packages/ludo_client && flutter test $_testFile --plain-name '$name'",
  );
}

String _f(double v) => v.toStringAsFixed(3);

String _pt(Offset p) => '(${_f(p.dx)}, ${_f(p.dy)})';

String _poly(Poly p) => p.map(_pt).join(' ');

// ---------------------------------------------------------------------------
// Plain geometry
// ---------------------------------------------------------------------------

double _signedArea(Poly p) {
  double s = 0;
  for (int i = 0; i < p.length; i++) {
    final Offset a = p[i];
    final Offset b = p[(i + 1) % p.length];
    s += a.dx * b.dy - b.dx * a.dy;
  }
  return s / 2;
}

/// Distance of [p] inside the clockwise (screen, y down) polygon [poly],
/// positive inside, negative outside: the smallest signed distance to any
/// non-degenerate edge line. Exact for convex polygons.
double _inset(Poly poly, Offset p) {
  double best = double.infinity;
  for (int i = 0; i < poly.length; i++) {
    final Offset a = poly[i];
    final Offset b = poly[(i + 1) % poly.length];
    final double len = (b - a).distance;
    if (len < 1e-9) {
      continue;
    }
    final double cross =
        (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    best = math.min(best, cross / len);
  }
  return best;
}

Poly _clockwise(Poly p) => _signedArea(p) >= 0 ? p : p.reversed.toList();

/// Mutual vertex containment: for convex polygons that is point-set
/// equality. Returns a description of the first difference, or null.
String? _differs(Poly got, Poly want, double eps) {
  final Poly g = _clockwise(got);
  final Poly w = _clockwise(want);
  for (final Offset v in g) {
    if (_inset(w, v) < -eps) {
      return 'vertex ${_pt(v)} of the drawn region is outside the expected '
          'shape ${_poly(w)}';
    }
  }
  for (final Offset v in w) {
    if (_inset(g, v) < -eps) {
      return 'vertex ${_pt(v)} of the expected shape is outside the region '
          '${_poly(g)}';
    }
  }
  return null;
}

/// The convex hull of [points] in clockwise screen order, built by sorting
/// round their mean (these shapes are all convex).
Poly _hull(List<Offset> points) {
  final List<Offset> uniq = <Offset>[];
  for (final Offset p in points) {
    if (!uniq.any((Offset q) => (q - p).distance < 1e-9)) {
      uniq.add(p);
    }
  }
  final Offset mean =
      uniq.fold(Offset.zero, (Offset a, Offset b) => a + b) /
      uniq.length.toDouble();
  uniq.sort((Offset a, Offset b) {
    final double aa = math.atan2(a.dy - mean.dy, a.dx - mean.dx);
    final double ab = math.atan2(b.dy - mean.dy, b.dx - mean.dx);
    return aa.compareTo(ab);
  });
  return uniq;
}

Offset _centre(double c) => Offset(7.5 * c, 7.5 * c);

Poly _square(double c) => <Offset>[
  Offset(6 * c, 6 * c),
  Offset(9 * c, 6 * c),
  Offset(9 * c, 9 * c),
  Offset(6 * c, 9 * c),
];

List<List<int>> _subsets({int minSize = 1}) {
  final List<List<int>> out = <List<int>>[];
  for (int mask = 1; mask < 16; mask++) {
    final List<int> seats = <int>[
      for (int s = 0; s < 4; s++)
        if (mask & (1 << s) != 0) s,
    ];
    if (seats.length >= minSize) {
      out.add(seats);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// R1 reference: a seat's entry side, and the angular partition
// ---------------------------------------------------------------------------

class _Side {
  const _Side(this.name, this.dir, this.a, this.b);

  final String name;

  /// Unit vector from the block's centre towards the middle of this side.
  final Offset dir;

  /// The two ends of the side (block corners).
  final Offset a;
  final Offset b;

  Offset get mid => (a + b) / 2;
}

/// The side of the block [6c, 9c] that the view cell of progress 56 touches.
_Side _sideOf(int seat, int quarters, double c) {
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
      'C-659t harness: seat $seat progress 56 maps to view cell '
      '(${out.col}, ${out.row}) at quarters $quarters, which does not touch '
      'a side of the centre block',
    );
  }
  final double near = 6 * c;
  final double far = 9 * c;
  if (out.col == 5) {
    return _Side(
      'left',
      const Offset(-1, 0),
      Offset(near, near),
      Offset(near, far),
    );
  }
  if (out.col == 9) {
    return _Side(
      'right',
      const Offset(1, 0),
      Offset(far, near),
      Offset(far, far),
    );
  }
  if (out.row == 5) {
    return _Side(
      'top',
      const Offset(0, -1),
      Offset(near, near),
      Offset(far, near),
    );
  }
  return _Side(
    'bottom',
    const Offset(0, 1),
    Offset(near, far),
    Offset(far, far),
  );
}

/// Sutherland-Hodgman against one half plane: keeps the points with
/// sign * cross(dir, p - origin) >= 0.
Poly _clip(Poly poly, Offset origin, Offset dir, double sign) {
  double side(Offset p) =>
      sign * (dir.dx * (p.dy - origin.dy) - dir.dy * (p.dx - origin.dx));
  final Poly out = <Offset>[];
  for (int i = 0; i < poly.length; i++) {
    final Offset cur = poly[i];
    final Offset nxt = poly[(i + 1) % poly.length];
    final double dc = side(cur);
    final double dn = side(nxt);
    if (dc >= 0) {
      out.add(cur);
    }
    if ((dc >= 0) != (dn >= 0)) {
      out.add(cur + (nxt - cur) * (dc / (dc - dn)));
    }
  }
  return out;
}

/// R1 as the contract words it: sort the seats by the angle of their entry
/// direction, the boundary between two consecutive ones is the ray halfway
/// along the arc between them, a region is the part of the square between
/// its two boundary rays.
Map<int, Poly> _oracle(List<int> seats, int quarters, double c) {
  if (seats.length == 1) {
    return <int, Poly>{seats.first: _square(c)};
  }
  final List<({int seat, double angle})> sorted = <({int seat, double angle})>[
    for (final int s in seats)
      (
        seat: s,
        angle: math.atan2(
          _sideOf(s, quarters, c).dir.dy,
          _sideOf(s, quarters, c).dir.dx,
        ),
      ),
  ]..sort((a, b) => a.angle.compareTo(b.angle));
  final int n = sorted.length;
  double gap(int i) {
    double g = sorted[(i + 1) % n].angle - sorted[i].angle;
    while (g <= 1e-9) {
      g += 2 * math.pi;
    }
    return g;
  }

  final Offset centre = _centre(c);
  final Map<int, Poly> out = <int, Poly>{};
  for (int i = 0; i < n; i++) {
    final double start = sorted[i].angle - gap((i - 1 + n) % n) / 2;
    final double end = sorted[i].angle + gap(i) / 2;
    Poly region = _square(c);
    region = _clip(region, centre, Offset(math.cos(start), math.sin(start)), 1);
    region = _clip(region, centre, Offset(math.cos(end), math.sin(end)), -1);
    out[sorted[i].seat] = region;
  }
  return out;
}

// ---------------------------------------------------------------------------
// R1: every subset, every quarter, two cell sizes
// ---------------------------------------------------------------------------

List<String> _regionMisses(List<int> seats, int quarters, double c) {
  final List<String> misses = <String>[];
  final Map<int, Poly> got;
  try {
    got = centreRegions(
      seatsInPlay: List<int>.of(seats),
      quarters: quarters,
      cellSize: c,
    );
  } catch (e) {
    return <String>['centreRegions threw instead of returning regions: $e'];
  }
  if (got.keys.toSet().difference(seats.toSet()).isNotEmpty ||
      seats.toSet().difference(got.keys.toSet()).isNotEmpty) {
    misses.add(
      'expected exactly the seats in play $seats as keys (nothing for a seat '
      'not in play), got ${got.keys.toList()}',
    );
  }
  final Map<int, Poly> want = _oracle(seats, quarters, c);
  double total = 0;
  for (final int seat in seats) {
    final Poly? p = got[seat];
    if (p == null) {
      continue;
    }
    final String who = 'seat $seat';
    if (p.length < 3) {
      misses.add(
        '$who: expected a polygon of at least 3 vertices, got ${p.length}',
      );
      continue;
    }
    if (p.any((Offset v) => !v.dx.isFinite || !v.dy.isFinite)) {
      misses.add('$who: expected finite vertices, got ${_poly(p)}');
      continue;
    }
    final double area = _signedArea(p);
    total += area.abs();
    if (area <= 0) {
      misses.add(
        '$who: expected vertices in clockwise screen order (positive '
        'shoelace area in y-down coordinates), got signed area ${_f(area)} '
        'for ${_poly(p)}',
      );
    }
    for (int i = 0; i < p.length; i++) {
      final Offset e1 = p[(i + 1) % p.length] - p[i];
      final Offset e2 = p[(i + 2) % p.length] - p[(i + 1) % p.length];
      if (e1.dx * e2.dy - e1.dy * e2.dx < -1e-9 * c * c) {
        misses.add(
          '$who: expected a convex polygon, vertex ${i + 1} turns the wrong way in ${_poly(p)}',
        );
        break;
      }
    }
    if (p.any(
      (Offset v) =>
          v.dx < 6 * c - 1e-9 ||
          v.dx > 9 * c + 1e-9 ||
          v.dy < 6 * c - 1e-9 ||
          v.dy > 9 * c + 1e-9,
    )) {
      misses.add(
        '$who: expected every vertex inside the block [${_f(6 * c)}, ${_f(9 * c)}], got ${_poly(p)}',
      );
    }
    if (seats.length > 1 &&
        !p.any((Offset v) => (v - _centre(c)).distance < 1e-6 * c)) {
      misses.add(
        '$who: expected the block centre ${_pt(_centre(c))} among the vertices, got ${_poly(p)}',
      );
    }
    final String? diff = _differs(p, want[seat]!, 1e-6 * c);
    if (diff != null) {
      misses.add(
        '$who: expected the region ${_poly(want[seat]!)} (the R1 angular '
        'partition), $diff',
      );
    }
    // The middle of the seat's own side, just inside, lies in the region.
    final _Side side = _sideOf(seat, quarters, c);
    final Offset probe = side.mid - side.dir * (0.15 * c);
    if (_inset(_clockwise(p), probe) <= 0) {
      misses.add(
        '$who: expected the point just inside the middle of its own '
        '${side.name} side ${_pt(probe)} inside its region, region is ${_poly(p)}',
      );
    }
  }
  final double wantTotal = 9 * c * c;
  if ((total - wantTotal).abs() > 1e-6 * wantTotal) {
    misses.add(
      'expected the areas to sum to 9 cell^2 = ${_f(wantTotal)}, got ${_f(total)}',
    );
  }
  // 13 x 13 grid strictly inside the block: exactly one region, the owner.
  int used = 0;
  for (int i = 0; i < 13; i++) {
    for (int j = 0; j < 13; j++) {
      final Offset p = Offset(
        6 * c + (i + 0.5) * 3 * c / 13,
        6 * c + (j + 0.5) * 3 * c / 13,
      );
      final List<int> owners = <int>[
        for (final int s in seats)
          if (_inset(want[s]!, p) > 1e-6 * c) s,
      ];
      if (owners.length != 1) {
        continue;
      }
      used++;
      final List<int> hit = <int>[
        for (final int s in seats)
          if (got[s] != null && _inset(_clockwise(got[s]!), p) > 1e-9 * c) s,
      ];
      if (hit.length != 1 || hit.first != owners.first) {
        misses.add(
          'grid point ($i, $j) at ${_pt(p)}: expected it in exactly region '
          'of seat ${owners.first}, found it in $hit',
        );
      }
    }
  }
  if (used < 100) {
    misses.add(
      'harness: only $used of 169 grid points were off every boundary',
    );
  }
  return misses;
}

// ---------------------------------------------------------------------------
// Widget harness
// ---------------------------------------------------------------------------

Widget _app({
  required Widget board,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
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
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: RepaintBoundary(child: board)),
  );
}

void _pin(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<int, List<int>> _tokens(List<int> seats, Map<int, List<int>> finished) =>
    <int, List<int>>{
      for (final int s in seats)
        s: <int>[
          for (int i = 0; i < 4; i++)
            (finished[s] ?? const <int>[]).contains(i) ? 57 : -1,
        ],
    };

class _Disc {
  _Disc(this.seat, this.index, this.rect);

  final int seat;
  final int index;
  final Rect rect;

  Offset get centre => rect.center;
}

class _Scene {
  _Scene({
    required this.seats,
    required this.mySeat,
    required this.finished,
    required this.origin,
    required this.cell,
    required this.discs,
    required this.badges,
  });

  final List<int> seats;
  final int? mySeat;
  final Map<int, List<int>> finished;
  final Offset origin;
  final double cell;
  final List<_Disc> discs;

  /// Badge rect in board-local px by seat, only for seats that have one.
  final Map<int, Rect> badges;

  int get quarters => viewQuarters(mySeat);

  String get text =>
      'seats $seats, mySeat ${mySeat ?? 'null'}, finished $finished';

  List<_Disc> discsOf(int seat) => <_Disc>[
    for (final _Disc d in discs)
      if (d.seat == seat) d,
  ];
}

int _boardCounter = 0;

Future<_Scene> _mount(
  WidgetTester tester, {
  required List<int> seats,
  required int? mySeat,
  required Map<int, List<int>> finished,
  Size surface = const Size(450, 450),
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  _pin(tester, surface);
  await tester.pumpWidget(
    _app(
      locale: locale,
      textScale: textScale,
      board: LudoBoard(
        key: ValueKey<int>(_boardCounter++),
        tokens: _tokens(seats, finished),
        seatsInPlay: seats,
        mySeat: mySeat,
      ),
    ),
  );
  await tester.pump();
  return _read(tester, seats, mySeat, finished);
}

_Scene _read(
  WidgetTester tester,
  List<int> seats,
  int? mySeat,
  Map<int, List<int>> finished,
) {
  final Offset origin = tester.getTopLeft(find.byType(LudoBoard));
  final double cell = tester.getSize(find.byType(LudoBoard)).width / 15;
  final List<_Disc> discs = <_Disc>[];
  final Map<int, Rect> badges = <int, Rect>{};
  for (final int seat in seats) {
    for (final int index in finished[seat] ?? const <int>[]) {
      final Finder f = find.byKey(Key('token-$seat-$index'));
      expect(
        f.evaluate().length,
        1,
        reason:
            'C-659t harness: expected exactly one token-$seat-$index widget '
            '(seats $seats, mySeat $mySeat, finished $finished)',
      );
      discs.add(_Disc(seat, index, tester.getRect(f).shift(-origin)));
    }
  }
  for (int seat = 0; seat < 4; seat++) {
    final Finder f = find.byKey(Key('board-finished-count-$seat'));
    if (f.evaluate().isNotEmpty) {
      badges[seat] = tester.getRect(f.first).shift(-origin);
    }
  }
  return _Scene(
    seats: seats,
    mySeat: mySeat,
    finished: finished,
    origin: origin,
    cell: cell,
    discs: discs,
    badges: badges,
  );
}

// ---------------------------------------------------------------------------
// R3: the stack
// ---------------------------------------------------------------------------

List<String> _stackMisses(_Scene s) {
  final List<String> misses = <String>[];
  final double c = s.cell;
  final Map<int, Poly> regions = centreRegions(
    seatsInPlay: List<int>.of(s.seats),
    quarters: s.quarters,
    cellSize: c,
  );
  final Map<int, Poly> oracle = _oracle(s.seats, s.quarters, c);
  final double diameter = c * 0.55;
  for (final int seat in s.seats) {
    final List<_Disc> discs = s.discsOf(seat);
    if (discs.isEmpty) {
      continue;
    }
    final _Side side = _sideOf(seat, s.quarters, c);
    final Poly region = _clockwise(regions[seat] ?? const <Offset>[]);
    final Poly want = _clockwise(oracle[seat]!);
    for (final _Disc d in discs) {
      final String who = 'seat $seat token ${d.index} at ${_pt(d.centre)}';
      if ((d.rect.width - diameter).abs() > 0.01 ||
          (d.rect.height - diameter).abs() > 0.01) {
        misses.add(
          '$who: expected a disc ${_f(diameter)} px square (0.55 cell), drawn '
          'box is ${_f(d.rect.width)} x ${_f(d.rect.height)}',
        );
      }
      final double r = d.rect.width / 2;
      if (region.length >= 3) {
        final double room = _inset(region, d.centre);
        if (room < r - 0.01) {
          misses.add(
            '$who: expected the disc radius ${_f(r)} clear of every edge of '
            'the region from centreRegions ${_poly(region)}, clearance is '
            '${_f(room)}',
          );
        }
      } else {
        misses.add('$who: centreRegions gave no usable region for seat $seat');
      }
      final double roomWant = _inset(want, d.centre);
      if (roomWant < r - 0.01) {
        misses.add(
          '$who: expected the disc radius ${_f(r)} clear of every edge of '
          'the R1 region ${_poly(want)}, clearance is ${_f(roomWant)}',
        );
      }
    }
    // Order along the stack: away from the seat's own side.
    final List<Offset> centres = <Offset>[for (final _Disc d in discs) d.centre]
      ..sort((Offset a, Offset b) {
        double dist(Offset p) =>
            (p - side.mid).dx * -side.dir.dx + (p - side.mid).dy * -side.dir.dy;
        return dist(a).compareTo(dist(b));
      });
    for (int k = 1; k < centres.length; k++) {
      final Offset v = centres[k] - centres[k - 1];
      final Offset v0 = centres[1] - centres[0];
      if ((v - v0).distance > 0.01) {
        misses.add(
          'seat $seat: expected every step of the stack to be the same '
          'vector, step 1 is ${_pt(v0)}, step $k is ${_pt(v)} '
          '(centres ${centres.map(_pt).join(' ')})',
        );
      }
      if (v.distance < 0.18 * diameter - 1e-6) {
        misses.add(
          'seat $seat: expected consecutive discs at least 0.18 x diameter = '
          '${_f(0.18 * diameter)} px apart, step $k is ${_f(v.distance)} px '
          '(centres ${centres.map(_pt).join(' ')})',
        );
      }
      final double away = v.dx * -side.dir.dx + v.dy * -side.dir.dy;
      if (away <= 0) {
        misses.add(
          'seat $seat: expected the stack to run from its ${side.name} base '
          'side inwards, step $k ${_pt(v)} has no component away from it',
        );
      }
      final Offset toCentre = _centre(c) - centres[0];
      if (v.dx * toCentre.dx + v.dy * toCentre.dy <= 0) {
        misses.add(
          'seat $seat: expected the stack to point towards the block centre '
          '${_pt(_centre(c))} from the base point ${_pt(centres[0])}, step '
          '$k is ${_pt(v)}',
        );
      }
    }
  }
  return misses;
}

// ---------------------------------------------------------------------------
// R4: the badge
// ---------------------------------------------------------------------------

Rect _paintedText(WidgetTester tester, Finder badge) {
  final Finder rich = find.descendant(
    of: badge,
    matching: find.byType(RichText),
  );
  final RenderParagraph p = tester.renderObject<RenderParagraph>(rich.first);
  final int len = p.text.toPlainText().length;
  final List<TextBox> boxes = p.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: len),
  );
  final Matrix4 toScreen = p.getTransformTo(null);
  Rect? out;
  for (final TextBox b in boxes) {
    final Rect r = MatrixUtils.transformRect(toScreen, b.toRect());
    out = out == null ? r : out.expandToInclude(r);
  }
  return out ?? Rect.zero;
}

Color? _badgeFill(WidgetTester tester, Finder badge) {
  final Finder boxes = find.descendant(
    of: badge,
    matching: find.byType(DecoratedBox),
    matchRoot: true,
  );
  for (final Element e in boxes.evaluate()) {
    final Decoration d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.shape == BoxShape.circle && d.color != null) {
      return d.color;
    }
  }
  return null;
}

double _hueGap(Color a, Color b) {
  final double d = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue)
      .abs();
  return math.min(d, 360 - d);
}

List<String> _badgeMisses(
  WidgetTester tester,
  _Scene s, {
  bool geometry = true,
}) {
  final List<String> misses = <String>[];
  for (int seat = 0; seat < 4; seat++) {
    final Finder badge = find.byKey(Key('board-finished-count-$seat'));
    final int n = s.seats.contains(seat)
        ? (s.finished[seat] ?? const <int>[]).length
        : 0;
    if (n == 0) {
      if (badge.evaluate().isNotEmpty) {
        misses.add(
          'seat $seat: expected no board-finished-count-$seat badge with 0 '
          'finished pieces, found ${badge.evaluate().length}',
        );
      }
      continue;
    }
    if (badge.evaluate().length != 1) {
      misses.add(
        'seat $seat: expected exactly one board-finished-count-$seat badge '
        'for $n finished pieces, found ${badge.evaluate().length}',
      );
      continue;
    }
    final Finder digits = find.descendant(of: badge, matching: find.text('$n'));
    if (digits.evaluate().length != 1) {
      misses.add(
        'seat $seat: expected one Text "$n" inside the badge, found '
        '${digits.evaluate().length}',
      );
      continue;
    }
    final Rect rect = tester.getRect(badge);
    if ((rect.width - rect.height).abs() > 0.01) {
      misses.add(
        'seat $seat: expected a round badge (square box), got '
        '${_f(rect.width)} x ${_f(rect.height)}',
      );
    }
    final bool wrapped =
        tester.widget(badge) is ExcludeSemantics ||
        find
            .ancestor(of: badge, matching: find.byType(ExcludeSemantics))
            .evaluate()
            .isNotEmpty ||
        find
            .descendant(of: badge, matching: find.byType(ExcludeSemantics))
            .evaluate()
            .isNotEmpty;
    if (!wrapped) {
      misses.add(
        'seat $seat: expected the badge wrapped in ExcludeSemantics (the '
        'board has no l10n of its own), found none on or around it',
      );
    }
    final Color? fill = _badgeFill(tester, badge);
    final Color seatColor = LudoColors.seats[seat];
    if (fill == null) {
      misses.add(
        'seat $seat: expected a DecoratedBox with a circular BoxDecoration '
        'colour on or under the badge key, found none',
      );
    }
    final RichText rich = tester.widget<RichText>(
      find.descendant(of: badge, matching: find.byType(RichText)).first,
    );
    final TextStyle? style = rich.text.style;
    if (style == null) {
      misses.add('seat $seat: the badge numeral has no text style');
    } else {
      final Color ink = style.color ?? const Color(0x00000000);
      if (ink.a < 1 || ink.r < 0.93 || ink.g < 0.93 || ink.b < 0.93) {
        misses.add('seat $seat: expected a white numeral, got $ink');
      }
      if (style.fontFamily != kLudoFontFamily ||
          style.fontWeight != FontWeight.w800 ||
          style.height != 1 ||
          style.fontFamilyFallback == null ||
          style.fontFamilyFallback!.join() != kLudoFontFallbacks.join()) {
        misses.add(
          'seat $seat: expected the place-medal digit style (family '
          '$kLudoFontFamily, fallbacks $kLudoFontFallbacks, w800, height 1), '
          'got family ${style.fontFamily}, fallbacks '
          '${style.fontFamilyFallback}, weight ${style.fontWeight}, height '
          '${style.height}',
        );
      }
      if (fill != null) {
        if (fill.a < 1) {
          misses.add('seat $seat: expected an opaque badge fill, got $fill');
        }
        if (fill.computeLuminance() >= seatColor.computeLuminance()) {
          misses.add(
            'seat $seat: expected the fill to be the seat colour darkened '
            '(darker than $seatColor), got $fill',
          );
        }
        if (_hueGap(fill, seatColor) > 25) {
          misses.add(
            'seat $seat: expected the fill to keep the seat colour hue '
            '(within 25 degrees of $seatColor), got $fill',
          );
        }
        final double ratio = contrastRatio(ink, fill);
        debugPrint(
          'C-659t measured contrast, seat $seat: numeral $ink on fill $fill '
          '= ${ratio.toStringAsFixed(2)}:1',
        );
        if (ratio < 3.0) {
          misses.add(
            'seat $seat: expected numeral/fill contrast of at least 3:1, got '
            '${ratio.toStringAsFixed(2)}:1 ($ink on $fill)',
          );
        }
      }
    }
    final Rect painted = _paintedText(tester, badge);
    final Rect room = rect.inflate(0.01);
    if (painted.left < room.left ||
        painted.right > room.right ||
        painted.top < room.top ||
        painted.bottom > room.bottom) {
      misses.add(
        'seat $seat: expected the painted numeral $painted inside the badge '
        '$rect, it is not',
      );
    }
    if (geometry) {
      final Rect local = rect.shift(-s.origin);
      final double r = local.width / 2;
      final Map<int, Poly> regions = centreRegions(
        seatsInPlay: List<int>.of(s.seats),
        quarters: s.quarters,
        cellSize: s.cell,
      );
      final Poly region = _clockwise(regions[seat] ?? const <Offset>[]);
      final Poly want = _clockwise(_oracle(s.seats, s.quarters, s.cell)[seat]!);
      if (region.length < 3 || _inset(region, local.center) < r - 0.01) {
        misses.add(
          'seat $seat: expected the badge circle (centre ${_pt(local.center)}, '
          'radius ${_f(r)}) inside the region from centreRegions '
          '${_poly(region)}',
        );
      }
      if (_inset(want, local.center) < r - 0.01) {
        misses.add(
          'seat $seat: expected the badge circle (centre ${_pt(local.center)}, '
          'radius ${_f(r)}) inside the R1 region ${_poly(want)}',
        );
      }
      for (final _Disc d in s.discsOf(seat)) {
        if ((d.centre - local.center).distance < r) {
          misses.add(
            'seat $seat: expected the badge beside the stack, it covers the '
            'centre ${_pt(d.centre)} of token ${d.index}',
          );
        }
      }
    }
  }
  return misses;
}

// ---------------------------------------------------------------------------
// R2 painter: pixel probe
// ---------------------------------------------------------------------------

Future<ByteData> _capture(WidgetTester tester, double side) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  expect(
    boundary.size,
    Size(side, side),
    reason:
        'C-659t harness: the board must fill the ${side}x$side viewport, got ${boundary.size}',
  );
  ByteData? pixels;
  await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
    pixels = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  });
  return pixels!;
}

// ---------------------------------------------------------------------------
// The cases
// ---------------------------------------------------------------------------

void main() {
  // ------------------------------------------------------------ case 1 (R1)
  group('R1 regions', () {
    for (final List<int> seats in _subsets()) {
      for (int q = 0; q < 4; q++) {
        final String name = 'R1 regions seats $seats quarters $q';
        test(name, () {
          final List<String> misses = <String>[];
          for (final double c in _cellSizes) {
            misses.addAll(
              _regionMisses(seats, q, c).map((String m) => 'cell $c: $m'),
            );
          }
          _failWith(
            name,
            'seatsInPlay $seats, quarters $q, cellSize $_cellSizes',
            misses,
          );
        });
      }
    }

    for (final List<int> seats in _subsets(minSize: 2)) {
      final String name =
          'R1 seat order and the caller list do not matter, seats $seats';
      test(name, () {
        final List<String> misses = <String>[];
        for (int q = 0; q < 4; q++) {
          final Map<int, Poly> base = centreRegions(
            seatsInPlay: List<int>.of(seats),
            quarters: q,
            cellSize: 30,
          );
          final List<List<int>> orders = <List<int>>[
            seats.reversed.toList(),
            <int>[...seats.skip(1), seats.first],
          ];
          for (final List<int> order in orders) {
            final List<int> frozen = List<int>.unmodifiable(order);
            final Map<int, Poly> got;
            try {
              got = centreRegions(
                seatsInPlay: frozen,
                quarters: q,
                cellSize: 30,
              );
            } catch (e) {
              misses.add(
                'quarters $q, order $order (an unmodifiable list): threw $e; '
                'the function must not sort or edit the caller list',
              );
              continue;
            }
            for (final int s in seats) {
              final String? diff = _differs(got[s]!, base[s]!, 1e-6);
              if (diff != null) {
                misses.add('quarters $q, order $order, seat $s: $diff');
              }
            }
          }
          final List<int> mine = <int>[...seats.reversed];
          centreRegions(seatsInPlay: mine, quarters: q, cellSize: 30);
          if (mine.join(',') != seats.reversed.join(',')) {
            misses.add(
              'quarters $q: the caller list $seats reversed was changed to $mine',
            );
          }
        }
        _failWith(name, 'seatsInPlay $seats in other orders', misses);
      });
    }
  });

  // ------------------------------------------------------------ case 2 (R1)
  group('R1 four seats are today\'s four triangles', () {
    for (int q = 0; q < 4; q++) {
      final String name = 'R1 four seats equal the four triangles, quarters $q';
      test(name, () {
        final List<String> misses = <String>[];
        for (final double c in _cellSizes) {
          final Map<int, Poly> got = centreRegions(
            seatsInPlay: const <int>[0, 1, 2, 3],
            quarters: q,
            cellSize: c,
          );
          for (int seat = 0; seat < 4; seat++) {
            final _Side side = _sideOf(seat, q, c);
            final Poly tri = <Offset>[side.a, side.b, _centre(c)];
            final String? diff = _differs(
              got[seat] ?? const <Offset>[],
              tri,
              1e-6 * c,
            );
            if (diff != null) {
              misses.add(
                'cell $c, seat $seat (${side.name} side): expected the '
                'triangle ${_poly(tri)}, $diff',
              );
            }
          }
        }
        _failWith(name, 'seatsInPlay [0, 1, 2, 3], quarters $q', misses);
      });
    }
  });

  // ------------------------------------------------------------ case 3 (R1)
  group('R1 named shapes', () {
    for (int q = 0; q < 4; q++) {
      for (final List<int> seats in <List<int>>[
        <int>[0, 2],
        <int>[1, 3],
      ]) {
        final String name =
            'R1 opposite seats $seats are two 3 x 1.5 rectangles, quarters $q';
        test(name, () {
          final List<String> misses = <String>[];
          for (final double c in _cellSizes) {
            final Map<int, Poly> got = centreRegions(
              seatsInPlay: List<int>.of(seats),
              quarters: q,
              cellSize: c,
            );
            for (final int seat in seats) {
              final _Side side = _sideOf(seat, q, c);
              final Offset in15 = -side.dir * (1.5 * c);
              final Poly rect = _hull(<Offset>[
                side.a,
                side.b,
                side.b + in15,
                side.a + in15,
              ]);
              final Poly g = got[seat] ?? const <Offset>[];
              final String? diff = _differs(g, rect, 1e-6 * c);
              if (diff != null) {
                misses.add(
                  'cell $c, seat $seat (${side.name} side): expected the '
                  'rectangle ${_poly(rect)} split through the centre, '
                  'perpendicular to the axis, $diff',
                );
              }
              if (g.length >= 3) {
                final double xs =
                    g.map((Offset p) => p.dx).reduce(math.max) -
                    g.map((Offset p) => p.dx).reduce(math.min);
                final double ys =
                    g.map((Offset p) => p.dy).reduce(math.max) -
                    g.map((Offset p) => p.dy).reduce(math.min);
                final double wantW = side.dir.dx != 0 ? 1.5 * c : 3 * c;
                final double wantH = side.dir.dx != 0 ? 3 * c : 1.5 * c;
                if ((xs - wantW).abs() > 1e-6 * c ||
                    (ys - wantH).abs() > 1e-6 * c) {
                  misses.add(
                    'cell $c, seat $seat: expected a bounding box '
                    '${_f(wantW)} x ${_f(wantH)} (axis aligned, 3 x 1.5 cells), '
                    'got ${_f(xs)} x ${_f(ys)}',
                  );
                }
                if ((_signedArea(g).abs() - 4.5 * c * c).abs() > 1e-6 * c * c) {
                  misses.add(
                    'cell $c, seat $seat: expected area ${_f(4.5 * c * c)}, got ${_f(_signedArea(g).abs())}',
                  );
                }
              }
            }
          }
          _failWith(name, 'seatsInPlay $seats, quarters $q', misses);
        });
      }

      for (final List<int> seats in <List<int>>[
        <int>[0, 1],
        <int>[1, 2],
        <int>[2, 3],
        <int>[0, 3],
      ]) {
        final String name =
            'R1 adjacent seats $seats are two right triangles split by the diagonal, quarters $q';
        test(name, () {
          final List<String> misses = <String>[];
          for (final double c in _cellSizes) {
            final Map<int, Poly> got = centreRegions(
              seatsInPlay: List<int>.of(seats),
              quarters: q,
              cellSize: c,
            );
            final _Side s0 = _sideOf(seats[0], q, c);
            final _Side s1 = _sideOf(seats[1], q, c);
            final List<Offset> shared = <Offset>[
              for (final Offset p in <Offset>[s0.a, s0.b])
                if ((p - s1.a).distance < 1e-9 || (p - s1.b).distance < 1e-9) p,
            ];
            if (shared.length != 1) {
              fail(
                'C-659t harness: sides ${s0.name} and ${s1.name} do not share one corner',
              );
            }
            final Offset far = _centre(c) * 2 - shared.single;
            for (final (int seat, _Side side) in <(int, _Side)>[
              (seats[0], s0),
              (seats[1], s1),
            ]) {
              final Poly tri = <Offset>[side.a, side.b, far];
              final Poly g = got[seat] ?? const <Offset>[];
              final String? diff = _differs(g, tri, 1e-6 * c);
              if (diff != null) {
                misses.add(
                  'cell $c, seat $seat (${side.name} side): expected the '
                  'right triangle ${_poly(tri)} cut by the diagonal through '
                  '${_pt(shared.single)} and ${_pt(far)}, $diff',
                );
              }
              if (g.length >= 3 &&
                  (_signedArea(g).abs() - 4.5 * c * c).abs() > 1e-6 * c * c) {
                misses.add(
                  'cell $c, seat $seat: expected area ${_f(4.5 * c * c)}, got ${_f(_signedArea(g).abs())}',
                );
              }
            }
          }
          _failWith(name, 'seatsInPlay $seats, quarters $q', misses);
        });
      }

      for (int gone = 0; gone < 4; gone++) {
        final List<int> seats = <int>[
          for (int s = 0; s < 4; s++)
            if (s != gone) s,
        ];
        final String name =
            'R1 three seats $seats, seat $gone empty, areas 2.25 and 3.375, quarters $q';
        test(name, () {
          final List<String> misses = <String>[];
          for (final double c in _cellSizes) {
            final Map<int, Poly> got = centreRegions(
              seatsInPlay: List<int>.of(seats),
              quarters: q,
              cellSize: c,
            );
            final _Side gap = _sideOf(gone, q, c);
            for (final int seat in seats) {
              final _Side side = _sideOf(seat, q, c);
              final Poly g = got[seat] ?? const <Offset>[];
              final bool opposite = (side.dir + gap.dir).distance < 1e-9;
              final Poly want;
              final double wantArea;
              if (opposite) {
                want = <Offset>[side.a, side.b, _centre(c)];
                wantArea = 2.25 * c * c;
              } else {
                final List<Offset> sharedCorner = <Offset>[
                  for (final Offset p in <Offset>[side.a, side.b])
                    if ((p - gap.a).distance < 1e-9 ||
                        (p - gap.b).distance < 1e-9)
                      p,
                ];
                if (sharedCorner.length != 1) {
                  fail(
                    'C-659t harness: seat $seat (${side.name}) shares no corner with the empty ${gap.name} side',
                  );
                }
                final Offset farEnd =
                    (side.a - sharedCorner.single).distance < 1e-9
                    ? side.b
                    : side.a;
                want = _hull(<Offset>[
                  farEnd,
                  sharedCorner.single,
                  gap.mid,
                  _centre(c),
                ]);
                wantArea = 3.375 * c * c;
              }
              final String? diff = _differs(g, want, 1e-6 * c);
              if (diff != null) {
                misses.add(
                  'cell $c, seat $seat (${side.name} side, '
                  '${opposite ? 'opposite the gap' : 'next to the gap'}): '
                  'expected ${_poly(want)}, $diff',
                );
              }
              if (g.length >= 3 &&
                  (_signedArea(g).abs() - wantArea).abs() > 1e-6 * c * c) {
                misses.add(
                  'cell $c, seat $seat (${side.name} side): expected area '
                  '${_f(wantArea)} (${opposite ? '2.25' : '3.375'} cell^2), '
                  'got ${_f(_signedArea(g).abs())}',
                );
              }
            }
          }
          _failWith(name, 'seatsInPlay $seats, quarters $q', misses);
        });
      }
    }

    for (int seat = 0; seat < 4; seat++) {
      final String name = 'R1 one seat ($seat) gets the whole 3 x 3 square';
      test(name, () {
        final List<String> misses = <String>[];
        for (int q = 0; q < 4; q++) {
          for (final double c in _cellSizes) {
            final Map<int, Poly> got = centreRegions(
              seatsInPlay: <int>[seat],
              quarters: q,
              cellSize: c,
            );
            final String? diff = _differs(
              got[seat] ?? const <Offset>[],
              _square(c),
              1e-6 * c,
            );
            if (diff != null || got.length != 1) {
              misses.add(
                'quarters $q, cell $c: expected only seat $seat with the square ${_poly(_square(c))}, got keys ${got.keys.toList()}; ${diff ?? ''}',
              );
            }
          }
        }
        _failWith(name, 'seatsInPlay [$seat]', misses);
      });
    }
  });

  // ------------------------------------------------------------ case 4 (R3)
  group('R3 stack', () {
    for (final List<int> seats in _subsets(minSize: 2)) {
      final List<int?> views = <int?>[null, ...seats];
      for (final int? mySeat in views) {
        final String name = 'R3 stack seats $seats mySeat ${mySeat ?? 'null'}';
        testWidgets(name, (WidgetTester tester) async {
          final List<String> misses = <String>[];
          final List<Map<int, List<int>>> scenes = <Map<int, List<int>>>[];
          for (int n = 1; n <= 4; n++) {
            scenes.add(<int, List<int>>{
              for (final int s in seats)
                s: <int>[for (int i = 0; i < n; i++) i],
            });
            if (n < 4) {
              scenes.add(<int, List<int>>{
                for (final int s in seats)
                  s: <int>[for (int i = 4 - n; i < 4; i++) i],
              });
            }
            if (mySeat == null) {
              for (final int only in seats) {
                scenes.add(<int, List<int>>{
                  only: <int>[for (int i = 0; i < n; i++) i],
                });
              }
            }
          }
          final Map<String, Set<String>> positions = <String, Set<String>>{};
          for (final Map<int, List<int>> finished in scenes) {
            final _Scene s = await _mount(
              tester,
              seats: seats,
              mySeat: mySeat,
              finished: finished,
            );
            misses.addAll(_stackMisses(s).map((String m) => '${s.text}: $m'));
            // The set of positions depends on how many are home, not on which.
            for (final int seat in seats) {
              final List<_Disc> d = s.discsOf(seat);
              if (d.isEmpty) {
                continue;
              }
              final Set<String> set = <String>{
                for (final _Disc x in d)
                  '${x.centre.dx.toStringAsFixed(2)},${x.centre.dy.toStringAsFixed(2)}',
              };
              final String key = 'seat $seat n ${d.length}';
              final Set<String>? seen = positions[key];
              if (seen == null) {
                positions[key] = set;
              } else if (seen.length != set.length || !seen.containsAll(set)) {
                misses.add(
                  '${s.text}: expected the $key finished pieces at the same '
                  'positions whichever token indices are home, saw $seen and '
                  '$set',
                );
              }
            }
          }
          _failWith(
            name,
            'LudoBoard 450x450 dpr 1.0, seats $seats, mySeat $mySeat, ${scenes.length} finished patterns',
            misses,
          );
        });
      }
    }

    testWidgets('R3 stack in Arabic, four seats, all home', (
      WidgetTester tester,
    ) async {
      const String name = 'R3 stack in Arabic, four seats, all home';
      final List<String> misses = <String>[];
      for (final int? mySeat in <int?>[null, 1]) {
        final _Scene s = await _mount(
          tester,
          seats: const <int>[0, 1, 2, 3],
          mySeat: mySeat,
          locale: const Locale('ar'),
          finished: <int, List<int>>{
            for (int seat = 0; seat < 4; seat++) seat: <int>[0, 1, 2, 3],
          },
        );
        misses.addAll(_stackMisses(s).map((String m) => '${s.text}: $m'));
      }
      _failWith(name, 'locale ar, 450x450', misses);
    });
  });

  // ------------------------------------------------------------ case 5 (R4)
  group('R4 count badge', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final String lang = locale.languageCode;
      for (final List<int> seats in <List<int>>[
        const <int>[0, 1, 2, 3],
        const <int>[0, 2],
        const <int>[1, 2, 3],
        const <int>[0, 1],
      ]) {
        final String name =
            'R4 badge shows N for 1..4, absent for 0, $lang, seats $seats';
        testWidgets(name, (WidgetTester tester) async {
          final List<String> misses = <String>[];
          final int mySeat = seats.first;
          for (int n = 0; n <= 4; n++) {
            final _Scene s = await _mount(
              tester,
              seats: seats,
              mySeat: mySeat,
              locale: locale,
              finished: <int, List<int>>{
                for (final int seat in seats)
                  seat: <int>[for (int i = 0; i < n; i++) i],
              },
            );
            misses.addAll(
              _badgeMisses(tester, s).map((String m) => '${s.text}: $m'),
            );
          }
          // A different count per seat, so a badge cannot borrow another seat's number.
          final Map<int, List<int>> mixed = <int, List<int>>{
            for (int i = 0; i < seats.length; i++)
              seats[i]: <int>[for (int k = 0; k < i; k++) k],
          };
          final _Scene m = await _mount(
            tester,
            seats: seats,
            mySeat: mySeat,
            locale: locale,
            finished: mixed,
          );
          misses.addAll(
            _badgeMisses(tester, m).map((String x) => '${m.text}: $x'),
          );
          _failWith(
            name,
            'LudoBoard 450x450 dpr 1.0, locale $lang, seats $seats, mySeat $mySeat, N 0..4 and mixed $mixed',
            misses,
          );
        });
      }
    }

    testWidgets('R4 the count follows the board live, 0 to 4', (
      WidgetTester tester,
    ) async {
      const String name = 'R4 the count follows the board live, 0 to 4';
      _pin(tester, const Size(450, 450));
      final List<String> misses = <String>[];
      Future<void> show(int n) async {
        await tester.pumpWidget(
          _app(
            board: LudoBoard(
              key: const ValueKey<String>('live'),
              tokens: <int, List<int>>{
                0: <int>[for (int i = 0; i < 4; i++) i < n ? 57 : -1],
                2: const <int>[-1, -1, -1, -1],
              },
              seatsInPlay: const <int>[0, 2],
              mySeat: 0,
            ),
          ),
        );
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      for (int n = 0; n <= 4; n++) {
        await show(n);
        final Finder badge = find.byKey(const Key('board-finished-count-0'));
        final Finder digits = find.descendant(
          of: badge,
          matching: find.text('$n'),
        );
        if (n == 0 && badge.evaluate().isNotEmpty) {
          misses.add('after $n finished: expected no badge, found one');
        }
        if (n > 0 && digits.evaluate().length != 1) {
          misses.add(
            'after $n finished and 4 s of frames: expected the badge to read "$n", found ${digits.evaluate().length} matching texts',
          );
        }
        if (find
            .byKey(const Key('board-finished-count-2'))
            .evaluate()
            .isNotEmpty) {
          misses.add(
            'after $n finished for seat 0: expected no badge for seat 2 (nothing home), found one',
          );
        }
      }
      _failWith(
        name,
        'seats [0, 2], mySeat 0, seat 0 finished count 0..4 over time',
        misses,
      );
    });

    for (final double scale in const <double>[1.0, 2.0]) {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        final String name =
            'R4 badge fits at text scale $scale on 360 x 760, ${locale.languageCode}';
        testWidgets(name, (WidgetTester tester) async {
          final List<String> misses = <String>[];
          for (final List<int> seats in <List<int>>[
            const <int>[0, 1, 2, 3],
            const <int>[0, 2],
            const <int>[1, 2, 3],
          ]) {
            final Map<int, List<int>> finished = <int, List<int>>{
              for (int i = 0; i < seats.length; i++)
                seats[i]: <int>[for (int k = 0; k <= (i + 0) % 4; k++) k],
            };
            final _Scene s = await _mount(
              tester,
              seats: seats,
              mySeat: seats.first,
              finished: finished,
              surface: const Size(360, 760),
              locale: locale,
              textScale: scale,
            );
            final Object? err = tester.takeException();
            if (err != null) {
              misses.add(
                '${s.text}: expected no overflow or other error, got $err',
              );
            }
            if (s.badges.length !=
                finished.values.where((List<int> l) => l.isNotEmpty).length) {
              misses.add(
                '${s.text}: expected a badge for every seat with a finished piece, found seats ${s.badges.keys.toList()}',
              );
            }
            misses.addAll(
              _badgeMisses(
                tester,
                s,
                geometry: false,
              ).map((String m) => '${s.text}: $m'),
            );
          }
          _failWith(
            name,
            '360 x 760 dpr 1.0, text scale $scale, locale ${locale.languageCode}',
            misses,
          );
        });
      }
    }

    testWidgets(
      'R4 four finished at text scale 2.0 does not overflow with the stack',
      (WidgetTester tester) async {
        const String name =
            'R4 four finished at text scale 2.0 does not overflow with the stack';
        final _Scene s = await _mount(
          tester,
          seats: const <int>[0, 1, 2, 3],
          mySeat: 0,
          finished: <int, List<int>>{
            for (int seat = 0; seat < 4; seat++) seat: <int>[0, 1, 2, 3],
          },
          surface: const Size(360, 760),
          textScale: 2.0,
        );
        final List<String> misses = <String>[];
        final Object? err = tester.takeException();
        if (err != null) {
          misses.add('expected no overflow or other error, got $err');
        }
        misses.addAll(_badgeMisses(tester, s, geometry: false));
        _failWith(
          name,
          '4 seats, all home, 360 x 760 dpr 1.0, text scale 2.0',
          misses,
        );
      },
    );
  });

  // -------------------------------------------------- R2 painter, pixels
  group('R2 painter', () {
    for (final List<int> seats in _subsets(minSize: 2)) {
      for (final int? mySeat in <int?>[null, seats.first]) {
        final String name =
            'R2 painter fills each region in its seat colour, seats $seats mySeat ${mySeat ?? 'null'}';
        testWidgets(name, (WidgetTester tester) async {
          final _Scene s = await _mount(
            tester,
            seats: seats,
            mySeat: mySeat,
            finished: const <int, List<int>>{},
          );
          final ByteData frame = await _capture(tester, 450);
          final double c = s.cell;
          final Map<int, Poly> want = _oracle(seats, s.quarters, c);
          final List<String> misses = <String>[];
          int used = 0;
          for (int i = 0; i < 13; i++) {
            for (int j = 0; j < 13; j++) {
              final Offset p = Offset(
                6 * c + (i + 0.5) * 3 * c / 13,
                6 * c + (j + 0.5) * 3 * c / 13,
              );
              final Offset d = p - _centre(c);
              if ((d.dx - d.dy).abs() / math.sqrt2 < 0.2 * c ||
                  (d.dx + d.dy).abs() / math.sqrt2 < 0.2 * c) {
                continue;
              }
              int? owner;
              for (final int seat in seats) {
                if (_inset(want[seat]!, p) >= 0.25 * c) {
                  owner = seat;
                }
              }
              if (owner == null) {
                continue;
              }
              used++;
              final int x = p.dx.floor();
              final int y = p.dy.floor();
              final int at = (y * 450 + x) * 4;
              final List<int> px = <int>[
                frame.getUint8(at),
                frame.getUint8(at + 1),
                frame.getUint8(at + 2),
                frame.getUint8(at + 3),
              ];
              final Color wantColor = LudoColors.seats[owner];
              final List<int> w = <int>[
                (wantColor.r * 255).round(),
                (wantColor.g * 255).round(),
                (wantColor.b * 255).round(),
                255,
              ];
              bool ok = true;
              for (int k = 0; k < 4; k++) {
                if ((px[k] - w[k]).abs() > 6) {
                  ok = false;
                }
              }
              if (!ok) {
                misses.add(
                  'grid ($i, $j) at ${_pt(p)}: expected seat $owner colour '
                  'rgba $w, read rgba $px',
                );
              }
            }
          }
          if (used < 20) {
            misses.add(
              'harness: only $used probe points were clear of boundaries and diagonals',
            );
          }
          _failWith(
            name,
            'LudoBoard 450x450 dpr 1.0, seats $seats, mySeat $mySeat, no finished pieces, no names',
            misses,
          );
        });
      }
    }
  });
}
