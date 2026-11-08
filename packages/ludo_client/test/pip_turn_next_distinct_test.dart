// Screen proofs for C-595 (work/ludo/orders/595-turn-and-next-pip-distinct.md,
// "Order 595t"), cases (a) to (e) plus the ugly cases named in the comments
// below. Written from the contract alone; the implementation is built in
// parallel in a tree this file's author has not read.
//
// A real GameScreen over a real RoomController on FakeTransport (the
// roll-tray and C-468 harnesses under test/support), every state a decoded
// wire frame. Nothing is mocked but the socket and the feedback service. The
// pips are read off the `game-seat-pip-*` keys.
//
// The contract: the next pip's ring becomes eight dashes (a public
// NextSeatRingPainter drawing one drawArc per dash), the turn pip's border
// goes to 2 dp ink and it gains one glow in its own seat colour; sizes, keys
// and the strip's height do not move. The file names NextSeatRingPainter, so
// it does not compile on a tree that lacks it; the cases that describe
// today's sizes and plain pips are green once it does compile.
//
// Every case is a fixed list of frames, there is no seed. A failure line names
// the case, the table, what the strip showed, and every frame pushed so far in
// order, which is the whole reproduction. Time is fake; the only waits are
// pumps of a stated length.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const Key _stripKey = Key('game-seat-pip-strip');
const Key _nextKey = Key('game-seat-pip-next');
const Key _turnKey = Key('game-seat-pip-turn');
const Key _shotKey = Key('pip-turn-next-shot');

Key _pipKey(int seat) => Key('game-seat-pip-$seat');

// --- tables ------------------------------------------------------------------

/// Seats [seats] named after [kNames], with Sam on seat [me].
List<Map<String, Object?>> _seatsOf(List<int> seats, {required int me}) =>
    <Map<String, Object?>>[
      for (final int seat in seats)
        seatJson(seat, name: seat == me ? 'Sam' : kNames[seat]!),
    ];

/// One mounted GameScreen, the log that makes a failure reproducible, and the
/// helpers every case reads the strip through.
class _T {
  _T(this.tester, this.drive, this.s, this.locale, this.setup, this.seats);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final Scn s;
  final Locale locale;
  final String setup;
  final List<int> seats;

  String? _frozen;

  /// Fixes the strip description now, for a case that replaces the tree.
  void freeze() => _frozen = observed;

  /// What the strip looks like right now, for a failure line.
  String get observed {
    final String? frozen = _frozen;
    if (frozen != null) {
      return frozen;
    }
    final StringBuffer out = StringBuffer();
    for (final int seat in seats) {
      final Finder pip = find.byKey(_pipKey(seat));
      if (pip.evaluate().isEmpty) {
        out.write('pip $seat: absent; ');
        continue;
      }
      final BoxDecoration? deco = _decorationOrNull(tester, _pipKey(seat));
      final Border? border = deco?.border as Border?;
      out.write(
        'pip $seat: ${tester.getSize(pip)} border '
        '${border == null ? 'none' : '${border.top.width} dp ${border.top.color}'}'
        ' shadows ${deco?.boxShadow?.length ?? 0}; ',
      );
    }
    out.write('ring painters ${_ringPainterCount(tester)}');
    return out.toString();
  }

  String why(String expected) =>
      'C-595 [${locale.languageCode}] $setup | expected: $expected | the strip '
      'shows: $observed | ${s.why('replay')}';

  Future<void> push(String type, Map<String, Object?> data) =>
      s.push(type, data);

  Future<void> pump(Duration d) => s.pump(d);
}

/// Mounts seat [me] of [seats] on a turn of [turnSeat] (a null [turnSeat] is a
/// PLAYING room with no turn at all).
Future<_T> _open(
  WidgetTester tester, {
  required String name,
  required List<int> seats,
  required int me,
  required int? turnSeat,
  Locale locale = _en,
  bool shot = false,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnSeat == null
        ? null
        : turnJson(seat: turnSeat, phase: 'await_roll', k: 0),
    seats: _seatsOf(seats, me: me),
    mySeat: me,
    players: seats.length,
  );
  if (shot) {
    await tester.pumpWidget(
      rollTrayHarness(
        RepaintBoundary(
          key: _shotKey,
          child: FeedbackScope(
            settings: FeedbackSettings.forTest(),
            service: drive.feedback,
            child: GameScreen(controller: drive.controller),
          ),
        ),
        locale: locale,
      ),
    );
    await tester.pump();
    await tester.pump();
  } else {
    await mountGame(tester, drive, locale: locale);
  }
  final String setup =
      'seats $seats me $me turn seat ${turnSeat ?? 'none'} await_roll k 0 '
      '$name';
  return _T(tester, drive, Scn(name, tester, drive), locale, setup, seats);
}

Future<void> _close(_T t) => releaseGame(t.tester, t.drive);

// --- reading the strip -------------------------------------------------------

/// The dot's decoration, whether the pip is a Container or a DecoratedBox.
BoxDecoration? _decorationOrNull(WidgetTester tester, Key key) {
  final Widget widget = tester.widget(find.byKey(key));
  if (widget is Container) {
    return widget.decoration as BoxDecoration?;
  }
  if (widget is DecoratedBox) {
    return widget.decoration as BoxDecoration?;
  }
  return null;
}

BoxDecoration _decoration(WidgetTester tester, Key key, String why) {
  final BoxDecoration? deco = _decorationOrNull(tester, key);
  if (deco == null) {
    fail('$why | the widget at $key has no BoxDecoration');
  }
  return deco;
}

/// The CustomPaint widgets in the tree that carry a foreground painter of the
/// ring's type.
Finder _ringPaints() => find.byWidgetPredicate(
  (Widget w) => w is CustomPaint && w.foregroundPainter is NextSeatRingPainter,
);

int _ringPainterCount(WidgetTester tester) => _ringPaints().evaluate().length;

/// Seats of [seats] whose pip dot has at least one BoxShadow.
List<int> _glowing(WidgetTester tester, List<int> seats) => <int>[
  for (final int seat in seats)
    if (find.byKey(_pipKey(seat)).evaluate().isNotEmpty &&
        (_decorationOrNull(tester, _pipKey(seat))?.boxShadow ??
                const <BoxShadow>[])
            .isNotEmpty)
      seat,
];

/// Seats of [seats] whose pip dot has a border.
List<int> _bordered(WidgetTester tester, List<int> seats) => <int>[
  for (final int seat in seats)
    if (find.byKey(_pipKey(seat)).evaluate().isNotEmpty &&
        _decorationOrNull(tester, _pipKey(seat))?.border != null)
      seat,
];

/// Largest per-channel difference of two colours, in 0..255 units.
double _dist(Color a, Color b) => math.max(
  math.max(((a.r - b.r) * 255).abs(), ((a.g - b.g) * 255).abs()),
  math.max(((a.b - b.b) * 255).abs(), ((a.a - b.a) * 255).abs()),
);

bool _sameColor(Color a, Color b) => _dist(a, b) < 0.5;

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

// --- the painter, recorded ---------------------------------------------------

/// One recorded canvas call of a painter.
class _Call {
  _Call(this.method, this.args);

  final Symbol method;
  final List<dynamic> args;
}

/// Mounts [painter] alone, at [size], and returns the calls it made while
/// painting, in order, plus the render object for the `paints` matcher.
Future<(List<_Call>, RenderObject)> _paintAlone(
  WidgetTester tester,
  CustomPainter painter,
  Size size,
) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: CustomPaint(
          key: const Key('ring-alone'),
          painter: painter,
          // A plain copy: a Size read off a render box remembers that box.
          size: Size(size.width, size.height),
        ),
      ),
    ),
  );
  final RenderObject render = tester.renderObject(
    find.byKey(const Key('ring-alone')),
  );
  final List<_Call> calls = <_Call>[];
  expect(
    render,
    paints..everything((Symbol method, List<dynamic> arguments) {
      calls.add(_Call(method, arguments));
      return true;
    }),
  );
  return (calls, render);
}

/// The CustomPaint under `game-seat-pip-next` that carries the ring.
CustomPaint _nextRingPaint(WidgetTester tester) {
  final Finder found = find.descendant(
    of: find.byKey(_nextKey),
    matching: find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.foregroundPainter != null,
    ),
  );
  expect(
    found,
    findsOneWidget,
    reason:
        'exactly one CustomPaint with a foregroundPainter under '
        'game-seat-pip-next',
  );
  return tester.widget<CustomPaint>(found);
}

// --- pixels ------------------------------------------------------------------

/// Reads pixels of the `_shotKey` boundary at 4 device pixels per logical one.
class _Shot {
  _Shot(this.origin, this.bytes, this.width, this.ratio);

  final Offset origin;
  final ByteData bytes;
  final int width;
  final double ratio;

  Color at(Offset global) {
    final int x = ((global.dx - origin.dx) * ratio).round();
    final int y = ((global.dy - origin.dy) * ratio).round();
    final int i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }
}

Future<_Shot> _shoot(WidgetTester tester) async {
  const double ratio = 4;
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  final ui.Image image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: ratio),
  ))!;
  final ByteData bytes = (await tester.runAsync<ByteData?>(
    () => image.toByteData(),
  ))!;
  return _Shot(
    tester.getTopLeft(find.byKey(_shotKey)),
    bytes,
    image.width,
    ratio,
  );
}

Offset _onCircle(Offset centre, double radius, double degrees) {
  final double rad = degrees * math.pi / 180;
  return centre + Offset(radius * math.cos(rad), radius * math.sin(rad));
}

// --- the shared assertions, run in both locales -------------------------------

/// (a): the painter under the next pip is a NextSeatRingPainter and painting it
/// records exactly eight arcs and no circle.
Future<void> _expectEightArcRing(_T t) async {
  final WidgetTester tester = t.tester;
  expect(
    t.drive.controller.room?.turn?.seat,
    isNotNull,
    reason: t.why('fixture: a turn is on'),
  );
  t.freeze();
  final CustomPaint ring = _nextRingPaint(tester);
  expect(
    ring.foregroundPainter,
    isA<NextSeatRingPainter>(),
    reason: t.why(
      'the CustomPaint under game-seat-pip-next has a foregroundPainter that '
      'is a NextSeatRingPainter, got ${ring.foregroundPainter.runtimeType}',
    ),
  );
  final Size size = tester.getSize(
    find.descendant(
      of: find.byKey(_nextKey),
      matching: find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.foregroundPainter != null,
      ),
    ),
  );
  final CustomPainter painter = ring.foregroundPainter!;
  final (List<_Call> calls, RenderObject render) = await _paintAlone(
    tester,
    painter,
    size,
  );
  final List<_Call> arcs = <_Call>[
    for (final _Call c in calls)
      if (c.method == #drawArc) c,
  ];
  final List<_Call> circles = <_Call>[
    for (final _Call c in calls)
      if (c.method == #drawCircle) c,
  ];
  final String drew = calls.map((_Call c) => c.method).join(', ');
  expect(
    arcs,
    hasLength(8),
    reason: t.why('eight drawArc calls, the painter made: $drew'),
  );
  expect(
    circles,
    isEmpty,
    reason: t.why('no drawCircle call, the painter made: $drew'),
  );
  expect(
    render,
    paints
      ..arc()
      ..arc()
      ..arc()
      ..arc()
      ..arc()
      ..arc()
      ..arc()
      ..arc(),
    reason: t.why('the paints matcher sees eight arc() calls'),
  );
  expect(
    render,
    isNot(paints..circle()),
    reason: t.why('the paints matcher sees no circle() call'),
  );
}

/// (b): the turn pip's dot has a 2 dp ink border and one glow in its own seat
/// colour.
void _expectTurnLight(_T t, int turnSeat) {
  final WidgetTester tester = t.tester;
  final BoxDecoration deco = _decoration(
    tester,
    _pipKey(turnSeat),
    t.why('turn pip $turnSeat decoration'),
  );
  expect(
    deco.shape,
    BoxShape.circle,
    reason: t.why('the turn pip stays a circle'),
  );
  expect(
    deco.color,
    LudoColors.seats[turnSeat],
    reason: t.why('the turn pip keeps its seat colour'),
  );
  final Border? border = deco.border as Border?;
  expect(
    border,
    isNotNull,
    reason: t.why('the turn pip $turnSeat has a border'),
  );
  for (final BorderSide side in <BorderSide>[
    border!.top,
    border.right,
    border.bottom,
    border.left,
  ]) {
    expect(
      side.width,
      2.0,
      reason: t.why('the turn pip border is 2 dp, got ${side.width}'),
    );
    expect(
      side.color,
      LudoColors.ink,
      reason: t.why('the turn pip border is ink, got ${side.color}'),
    );
    expect(
      side.style,
      BorderStyle.solid,
      reason: t.why('the turn pip border is solid'),
    );
  }
  final List<BoxShadow> shadows = deco.boxShadow ?? const <BoxShadow>[];
  expect(
    shadows,
    hasLength(1),
    reason: t.why('the turn pip carries exactly one BoxShadow'),
  );
  final BoxShadow glow = shadows.single;
  final Color want = LudoColors.seats[turnSeat].withValues(alpha: 0.6);
  expect(
    _sameColor(glow.color, want),
    isTrue,
    reason: t.why(
      'the glow is seat $turnSeat colour at alpha 0.6 (${_hex(want)}), got '
      '${_hex(glow.color)}',
    ),
  );
  expect(
    glow.blurRadius,
    6.0,
    reason: t.why('glow blur 6, got ${glow.blurRadius}'),
  );
  expect(
    glow.spreadRadius,
    1.5,
    reason: t.why('glow spread 1.5, got ${glow.spreadRadius}'),
  );
  expect(
    glow.offset,
    Offset.zero,
    reason: t.why('the glow is centred on the pip, got ${glow.offset}'),
  );
}

void main() {
  // ===========================================================================
  // (a) the next ring is eight dashes.
  // ===========================================================================
  testWidgets('C-595 (a) en: the next pip\'s foreground painter is a '
      'NextSeatRingPainter and paints exactly 8 arcs and no circle', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'a',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      await _expectEightArcRing(t);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (a) en: the eight arcs are 22.5 degree dashes in 45 '
      'degree slots, first at the top, on the ring circle, round ink strokes '
      'of 1.5 dp at alpha 0.7', (tester) async {
    final _T t = await _open(
      tester,
      name: 'a geometry',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      final CustomPaint ring = _nextRingPaint(tester);
      final Size size = tester.getSize(
        find.descendant(
          of: find.byKey(_nextKey),
          matching: find.byWidgetPredicate(
            (Widget w) => w is CustomPaint && w.foregroundPainter != null,
          ),
        ),
      );
      expect(
        size,
        const Size(15, 15),
        reason: t.why('the ring paints around the 15 dp next pip'),
      );
      t.freeze();
      final (List<_Call> calls, _) = await _paintAlone(
        tester,
        ring.foregroundPainter!,
        size,
      );
      final List<_Call> arcs = <_Call>[
        for (final _Call c in calls)
          if (c.method == #drawArc) c,
      ];
      expect(
        arcs,
        hasLength(8),
        reason: t.why('eight drawArc calls to read the geometry from'),
      );
      const double slot = math.pi / 4;
      for (int i = 0; i < arcs.length; i++) {
        final List<dynamic> a = arcs[i].args;
        final Rect rect = a[0] as Rect;
        final double start = a[1] as double;
        final double sweep = a[2] as double;
        final bool useCenter = a[3] as bool;
        final Paint paint = a[4] as Paint;
        final String at = 'arc $i of ${arcs.length}';
        expect(
          start,
          closeTo(-math.pi / 2 + i * slot, 1e-6),
          reason: t.why(
            '$at starts at ${-90 + 45 * i} degrees, got '
            '${start * 180 / math.pi}',
          ),
        );
        expect(
          sweep,
          closeTo(slot / 2, 1e-6),
          reason: t.why(
            '$at sweeps 22.5 degrees, got ${sweep * 180 / math.pi}',
          ),
        );
        expect(useCenter, isFalse, reason: t.why('$at is an open arc'));
        expect(
          rect.center.dx,
          closeTo(size.width / 2, 1e-6),
          reason: t.why('$at is centred on the pip, got ${rect.center}'),
        );
        expect(
          rect.center.dy,
          closeTo(size.height / 2, 1e-6),
          reason: t.why('$at is centred on the pip, got ${rect.center}'),
        );
        expect(
          rect.width,
          closeTo(2 * (size.width / 2 + 2.5), 1e-6),
          reason: t.why(
            '$at is on the circle of radius pip radius + 2.5 dp (width '
            '${2 * (size.width / 2 + 2.5)}), got ${rect.width}',
          ),
        );
        expect(
          rect.height,
          closeTo(rect.width, 1e-6),
          reason: t.why('$at is on a circle, got $rect'),
        );
        expect(
          paint.style,
          PaintingStyle.stroke,
          reason: t.why('$at is stroked'),
        );
        expect(
          paint.strokeWidth,
          1.5,
          reason: t.why('$at stroke is 1.5 dp, got ${paint.strokeWidth}'),
        );
        expect(
          paint.strokeCap,
          StrokeCap.round,
          reason: t.why('$at has round caps, got ${paint.strokeCap}'),
        );
        final Color want = LudoColors.ink.withValues(alpha: 0.7);
        expect(
          _sameColor(paint.color, want),
          isTrue,
          reason: t.why(
            '$at is ink at alpha 0.7 (${_hex(want)}), got ${_hex(paint.color)}',
          ),
        );
      }
    } finally {
      await _close(t);
    }
  });

  test('C-595 (a) the painter publishes its constants: gap 2.5, stroke 1.5, '
      '8 dashes, alpha 0.7', () {
    expect(NextSeatRingPainter.gap, 2.5, reason: 'C-595 D1 gap');
    expect(NextSeatRingPainter.stroke, 1.5, reason: 'C-595 D1 stroke');
    expect(NextSeatRingPainter.dashes, 8, reason: 'C-595 D1 dashes');
    expect(NextSeatRingPainter.alpha, 0.7, reason: 'C-595 D1 alpha');
  });

  testWidgets('C-595 (a) en: pixels. Around the next pip the ring is broken: '
      'ink in the middle of each dash, the table showing in the middle of '
      'each gap', (tester) async {
    // Four seats, I am seat 0, seat 3 on turn: the next pip is seat 0 at the
    // left end of the strip, the turn pip (and its glow) is at the far end,
    // and the pip beside it is plain, so nothing else touches the ring. Only
    // the upper half of the ring is sampled, away from the row's edges.
    final _T t = await _open(
      tester,
      name: 'a pixels',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      turnSeat: 3,
      shot: true,
    );
    try {
      await t.pump(const Duration(milliseconds: 100));
      final _Shot shot = await _shoot(tester);
      final Offset centre = tester.getCenter(find.byKey(_pipKey(0)));
      final double r = tester.getSize(find.byKey(_pipKey(0))).width / 2;
      final double ringR = r + 2.5;
      final double outsideR = r + 6.0;
      // Dash i covers [-90 + 45 i, -90 + 45 i + 22.5]; its middle is +11.25,
      // the middle of the gap after it +33.75.
      final List<double> dashMids = <double>[-78.75, -33.75, -123.75, -168.75];
      final List<double> gapMids = <double>[-56.25, -11.25, -101.25, -146.25];
      for (final double a in dashMids) {
        final Color ink = shot.at(_onCircle(centre, ringR, a));
        final Color table = shot.at(_onCircle(centre, outsideR, a));
        expect(
          _dist(ink, table) > 50,
          isTrue,
          reason: t.why(
            'the middle of a dash (radius $ringR, $a deg) is drawn in ink, '
            'got ${_hex(ink)} against the table ${_hex(table)}',
          ),
        );
      }
      for (final double a in gapMids) {
        final Color gap = shot.at(_onCircle(centre, ringR, a));
        final Color table = shot.at(_onCircle(centre, outsideR, a));
        expect(
          _dist(gap, table) < 12,
          isTrue,
          reason: t.why(
            'the middle of a gap (radius $ringR, $a deg) shows the table '
            '${_hex(table)}, got ${_hex(gap)}',
          ),
        );
      }
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (a) ar: the Arabic table has the same eight arc ring', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'a ar',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      locale: _ar,
    );
    try {
      await _expectEightArcRing(t);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (b) the turn pip: 2 dp ink border and one glow in its own colour.
  // ===========================================================================
  testWidgets('C-595 (b) en: the turn pip has a 2 dp ink border and one '
      'glow in seat 1\'s colour at alpha 0.6, blur 6, spread 1.5', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'b',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      _expectTurnLight(t, 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (b) ar: the Arabic table has the same turn pip border '
      'and glow', (tester) async {
    final _T t = await _open(
      tester,
      name: 'b ar',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      locale: _ar,
    );
    try {
      _expectTurnLight(t, 1);
    } finally {
      await _close(t);
    }
  });

  for (final int turnSeat in <int>[0, 2, 3]) {
    testWidgets('C-595 (b) en: with seat $turnSeat on turn its pip, not seat '
        '1\'s, wears the border and the glow in its own colour', (
      tester,
    ) async {
      final _T t = await _open(
        tester,
        name: 'b turn $turnSeat',
        seats: const <int>[0, 1, 2, 3],
        me: 2,
        turnSeat: turnSeat,
      );
      try {
        _expectTurnLight(t, turnSeat);
        expect(_glowing(tester, t.seats), <int>[
          turnSeat,
        ], reason: t.why('only pip $turnSeat glows'));
      } finally {
        await _close(t);
      }
    });
  }

  testWidgets('C-595 (b) en: the light follows the turn. After the turn '
      'moves 1 -> 2 -> 3 -> 0 exactly one pip glows and one ring is drawn, '
      'and a replayed turn frame adds nothing', (tester) async {
    final _T t = await _open(
      tester,
      name: 'b follows',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      for (final int seat in <int>[2, 3, 0]) {
        await t.push('turn', turnFrame(seat));
        await t.pump(const Duration(milliseconds: 100));
        _expectTurnLight(t, seat);
        expect(_glowing(tester, t.seats), <int>[
          seat,
        ], reason: t.why('after the turn moved to $seat only its pip glows'));
        expect(
          _ringPainterCount(tester),
          1,
          reason: t.why('after the turn moved to $seat one ring is drawn'),
        );
        expect(
          find.descendant(
            of: find.byKey(_turnKey),
            matching: find.byKey(_pipKey(seat)),
          ),
          findsOneWidget,
          reason: t.why('game-seat-pip-turn holds pip $seat'),
        );
      }
      await t.push('turn', turnFrame(0));
      await t.pump(const Duration(milliseconds: 100));
      expect(_glowing(tester, t.seats), <int>[
        0,
      ], reason: t.why('a replayed turn frame leaves one glow'));
      expect(_bordered(tester, t.seats), <int>[
        0,
      ], reason: t.why('a replayed turn frame leaves one border'));
      expect(
        _ringPainterCount(tester),
        1,
        reason: t.why('a replayed turn frame leaves one ring'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 three seats [0,1,2], me 0, turn 2 wraps: seat 2 glows '
      'in its own colour and the ring is on seat 0', (tester) async {
    final _T t = await _open(
      tester,
      name: 'wrap',
      seats: const <int>[0, 1, 2],
      me: 0,
      turnSeat: 2,
    );
    try {
      _expectTurnLight(t, 2);
      expect(
        find.descendant(
          of: find.byKey(_nextKey),
          matching: find.byKey(_pipKey(0)),
        ),
        findsOneWidget,
        reason: t.why('the next pip wraps to seat 0'),
      );
      expect(
        _ringPainterCount(tester),
        1,
        reason: t.why('one ring at a three seat table'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 two seats [1,2], me 2, turn 1: the pair has the glow and '
      'the ring too', (tester) async {
    final _T t = await _open(
      tester,
      name: 'pair',
      seats: const <int>[1, 2],
      me: 2,
      turnSeat: 1,
    );
    try {
      _expectTurnLight(t, 1);
      expect(
        _ringPainterCount(tester),
        1,
        reason: t.why('one ring at a two seat table'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (c) plain pips and the next pip's dot are bare.
  // ===========================================================================
  testWidgets('C-595 (c) en: a plain pip (seat 3) has no border and no '
      'shadow; the next pip\'s dot (seat 2) has no border and no shadow', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'c',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      for (final int seat in <int>[3, 0, 2]) {
        final BoxDecoration deco = _decoration(
          tester,
          _pipKey(seat),
          t.why('pip $seat decoration'),
        );
        expect(
          deco.border,
          isNull,
          reason: t.why(
            '${seat == 2 ? 'the next pip\'s dot' : 'plain pip $seat'} has no '
            'border',
          ),
        );
        expect(
          deco.boxShadow == null || deco.boxShadow!.isEmpty,
          isTrue,
          reason: t.why(
            '${seat == 2 ? 'the next pip\'s dot' : 'plain pip $seat'} has no '
            'shadow, got ${deco.boxShadow}',
          ),
        );
        expect(
          deco.color,
          LudoColors.seats[seat],
          reason: t.why('pip $seat keeps its seat colour'),
        );
        expect(
          deco.shape,
          BoxShape.circle,
          reason: t.why('pip $seat stays a circle'),
        );
      }
      expect(
        _glowing(tester, t.seats).contains(2) ||
            _glowing(tester, t.seats).contains(3),
        isFalse,
        reason: t.why('neither the next nor a plain pip glows'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (c) en: a PLAYING room with no turn draws no ring, no '
      'turn pip, and no pip with a border or a glow', (tester) async {
    final _T t = await _open(
      tester,
      name: 'c no turn',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: null,
    );
    try {
      expect(
        find.byKey(_turnKey),
        findsNothing,
        reason: t.why('no turn pip without a turn'),
      );
      expect(
        find.byKey(_nextKey),
        findsNothing,
        reason: t.why('no next pip without a turn'),
      );
      expect(
        _ringPainterCount(tester),
        0,
        reason: t.why('no ring without a turn'),
      );
      expect(
        _glowing(tester, t.seats),
        isEmpty,
        reason: t.why('no pip glows without a turn'),
      );
      expect(
        _bordered(tester, t.seats),
        isEmpty,
        reason: t.why('no pip has a border without a turn'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (c) en: only the turn pip has a border or a glow, and '
      'only the next pip has a ring', (tester) async {
    final _T t = await _open(
      tester,
      name: 'c exclusive',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      expect(_bordered(tester, t.seats), <int>[
        1,
      ], reason: t.why('only pip 1 has a border'));
      expect(_glowing(tester, t.seats), <int>[
        1,
      ], reason: t.why('only pip 1 glows'));
      expect(
        _ringPainterCount(tester),
        1,
        reason: t.why('exactly one ring in the whole screen'),
      );
      expect(
        find.descendant(of: _ringPaints(), matching: find.byKey(_pipKey(2))),
        findsOneWidget,
        reason: t.why('the ring is around pip 2, the next seat'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (d) laid-out sizes do not move.
  // ===========================================================================
  testWidgets('C-595 (d) en: laid-out sizes are turn 18, next 15, plain 12, '
      'the ring adds nothing to the next pip\'s box, and the keys are all '
      'still there once', (tester) async {
    final _T t = await _open(
      tester,
      name: 'd sizes',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      final Map<int, double> want = <int, double>{1: 18, 2: 15, 0: 12, 3: 12};
      for (final MapEntry<int, double> e in want.entries) {
        expect(
          find.byKey(_pipKey(e.key)),
          findsOneWidget,
          reason: t.why('game-seat-pip-${e.key} is on screen once'),
        );
        final Size size = tester.getSize(find.byKey(_pipKey(e.key)));
        expect(
          size.width,
          closeTo(e.value, 0.01),
          reason: t.why('pip ${e.key} is ${e.value} wide, got $size'),
        );
        expect(
          size.height,
          closeTo(e.value, 0.01),
          reason: t.why('pip ${e.key} is ${e.value} high, got $size'),
        );
      }
      expect(
        find.byKey(_turnKey),
        findsOneWidget,
        reason: t.why('game-seat-pip-turn once'),
      );
      expect(
        find.byKey(_nextKey),
        findsOneWidget,
        reason: t.why('game-seat-pip-next once'),
      );
      expect(
        tester.getSize(
          find.descendant(
            of: find.byKey(_nextKey),
            matching: find.byWidgetPredicate(
              (Widget w) => w is CustomPaint && w.foregroundPainter != null,
            ),
          ),
        ),
        const Size(15, 15),
        reason: t.why('the next pip\'s box is the dot alone, 15 x 15'),
      );
      expect(
        tester.getSize(find.byKey(_turnKey)),
        const Size(18, 18),
        reason: t.why('the turn pip\'s box is the dot alone, 18 x 18'),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no layout or paint exception'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-595 (d) en: the strip is 18 dp of pip plus its own padding '
      'high at a four seat table and at a two seat table', (tester) async {
    final List<String> seen = <String>[];
    final List<double> heights = <double>[];
    for (final List<int> seats in <List<int>>[
      const <int>[0, 1, 2, 3],
      const <int>[1, 2],
    ]) {
      final _T t = await _open(
        tester,
        name: 'd strip ${seats.length} seats',
        seats: seats,
        me: 2,
        turnSeat: 1,
      );
      try {
        final Rect strip = tester.getRect(find.byKey(_stripKey));
        heights.add(strip.height);
        seen.add('${seats.length} seats: strip $strip');
        expect(
          strip.height,
          closeTo(18 + 2 * kSpace2, 0.01),
          reason: t.why(
            'the strip is the 18 dp turn pip plus ${2 * kSpace2} dp of '
            'padding high, got ${strip.height}',
          ),
        );
      } finally {
        await _close(t);
      }
    }
    expect(
      heights[0],
      closeTo(heights[1], 0.01),
      reason:
          'C-595 (d) the strip height at a four seat table (${heights[0]}) '
          'equals the strip height at a two seat table (${heights[1]}) | '
          '${seen.join(' | ')}',
    );
  });

  testWidgets('C-595 (d) en: the strip height does not change as the turn '
      'walks round a four seat table', (tester) async {
    final _T t = await _open(
      tester,
      name: 'd walk',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
    );
    try {
      final double first = tester.getSize(find.byKey(_stripKey)).height;
      for (final int seat in <int>[1, 2, 3, 0]) {
        await t.push('turn', turnFrame(seat));
        await t.pump(const Duration(milliseconds: 100));
        expect(
          tester.getSize(find.byKey(_stripKey)).height,
          closeTo(first, 0.01),
          reason: t.why('the strip is $first high with seat $seat on turn'),
        );
        expect(
          tester.getSize(find.byKey(_turnKey)),
          const Size(18, 18),
          reason: t.why('the turn pip is 18 x 18 with seat $seat on turn'),
        );
      }
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (e) Arabic sizes, to be sure nothing is mirrored out of shape.
  // ===========================================================================
  testWidgets('C-595 (e) ar: laid-out sizes are turn 18, next 15, plain 12 '
      'in the Arabic table', (tester) async {
    final _T t = await _open(
      tester,
      name: 'e ar sizes',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      locale: _ar,
    );
    try {
      expect(
        tester.getSize(find.byKey(_pipKey(1))),
        const Size(18, 18),
        reason: t.why('the turn pip is 18 x 18'),
      );
      expect(
        tester.getSize(find.byKey(_pipKey(2))),
        const Size(15, 15),
        reason: t.why('the next pip is 15 x 15'),
      );
      expect(
        tester.getSize(find.byKey(_pipKey(3))),
        const Size(12, 12),
        reason: t.why('a plain pip is 12 x 12'),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no exception in RTL'),
      );
    } finally {
      await _close(t);
    }
  });
}
