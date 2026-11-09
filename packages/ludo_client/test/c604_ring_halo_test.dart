// Acceptance tests for work/ludo/orders/604-ring-and-flash-halo.md (C-604),
// written from that contract's text alone, order 604t. The implementation
// (order 604) is built in parallel by another worker; on the base commit
// 58d59d8 the halo cases below are expected to fail and the unchanged-
// geometry and nothing-painted cases are expected to pass.
//
// Method: render a keyed RepaintBoundary to an image at a high pixel ratio
// (so a 1 dp halo is several pixels wide), then walk rays outward from a
// known centre and classify every pixel as near-white (within 10 per channel
// of LudoColors.actionOn), green (within 10 of LudoColors.success) or other.
// Every expected colour comes from LudoColors; no sampled value is pasted as
// a literal. The scenario in every failure message (seat, token, progress,
// angle, pixel ratio) is the whole recipe to reproduce it: there is no
// randomness anywhere in this file.
//
// Steady ring: the board cases run under MediaQuery(disableAnimations: true)
// so the ring holds 3.5 dp at opacity 1.0 and the colours are exact.
//
// Ambiguities found while writing, reported rather than invented around:
//   1. D1 lets the implementation either keep the ring's centre line and let
//      the halo overhang the painter box by 1 dp, or deflate by the halo's
//      half width so the green band moves in by 1 dp. The size case below
//      therefore accepts a painted outer radius from the box radius minus
//      0.5 dp to the box radius plus 1 dp (plus anti-alias slack).
//   2. (d) says the ring band is "error blended at ringOpacity over what is
//      under it". Under D3 what is under the red band is the halo, drawn at
//      the same opacity. The band check accepts either composite: red over
//      halo over the base, or red over the base alone.
//   3. D3 does not say whether the halo hangs inside, outside or around the
//      red band's box. The edge checks only require a near-white pixel in a
//      window just inside the band's inner edge and one just outside its
//      outer edge, with the band's geometry taken from the base's ring
//      (a border of max(2, side * 0.1) inside the scaled box).

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
import 'package:ludo_client/src/landing_marks.dart';
import 'package:ludo_client/src/theme.dart';

// ---------------------------------------------------------------------------
// Pixels.
// ---------------------------------------------------------------------------

int _ch(double unit) => (unit * 255).round();

/// A rendered image with logical-coordinate sampling.
class _Shot {
  _Shot(this.width, this.height, this.ratio, this.data);

  final int width;
  final int height;
  final double ratio;
  final ByteData data;

  /// The RGB of the pixel under logical point ([x], [y]), 0..255 each.
  List<int> at(double x, double y) {
    final int px = (x * ratio).floor().clamp(0, width - 1);
    final int py = (y * ratio).floor().clamp(0, height - 1);
    final int i = (py * width + px) * 4;
    return <int>[data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  }
}

Future<_Shot> _shoot(
  WidgetTester tester,
  GlobalKey key, {
  required double ratio,
}) async {
  final RenderRepaintBoundary boundary = tester.renderObject(find.byKey(key));
  late _Shot shot;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: ratio);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    shot = _Shot(image.width, image.height, ratio, bytes!);
    image.dispose();
  });
  return shot;
}

List<int> _rgb(Color c) => <int>[_ch(c.r), _ch(c.g), _ch(c.b)];

bool _near(List<int> a, List<int> b, int tol) {
  for (int i = 0; i < 3; i++) {
    if ((a[i] - b[i]).abs() > tol) {
      return false;
    }
  }
  return true;
}

/// [top] at [alpha] composited over [under], per channel, unrounded.
List<double> _over(List<int> top, double alpha, List<double> under) => <double>[
  for (int i = 0; i < 3; i++) top[i] * alpha + under[i] * (1 - alpha),
];

bool _nearD(List<int> px, List<double> expected, double tol) {
  for (int i = 0; i < 3; i++) {
    if ((px[i] - expected[i]).abs() > tol) {
      return false;
    }
  }
  return true;
}

String _hex(List<int> c) =>
    '#${c.map((int v) => v.toRadixString(16).padLeft(2, '0')).join()}';

// ---------------------------------------------------------------------------
// Rays and the near-white / green / near-white crossing.
// ---------------------------------------------------------------------------

enum _Kind { white, green, other }

class _Run {
  _Run(this.kind, this.from, this.to, this.samples);

  final _Kind kind;
  final double from;
  final double to;
  final int samples;

  @override
  String toString() =>
      '${kind.name}[${from.toStringAsFixed(2)}..${to.toStringAsFixed(2)}]';
}

final List<int> _whiteRef = _rgb(LudoColors.actionOn);
final List<int> _greenRef = _rgb(LudoColors.success);

_Kind _classify(List<int> px) {
  if (_near(px, _whiteRef, 10)) {
    return _Kind.white;
  }
  if (_near(px, _greenRef, 10)) {
    return _Kind.green;
  }
  return _Kind.other;
}

/// Walks outward from [centre] along [angle] from [r0] to [r1] in steps of
/// one image pixel and returns the runs of equal classification.
List<_Run> _ray(_Shot shot, Offset centre, double angle, double r0, double r1) {
  final double step = 1 / shot.ratio;
  final List<_Run> runs = <_Run>[];
  _Kind? kind;
  double from = r0;
  int count = 0;
  double last = r0;
  for (double r = r0; r <= r1; r += step) {
    final List<int> px = shot.at(
      centre.dx + math.cos(angle) * r,
      centre.dy + math.sin(angle) * r,
    );
    final _Kind k = _classify(px);
    if (k != kind) {
      if (kind != null) {
        runs.add(_Run(kind, from, last, count));
      }
      kind = k;
      from = r;
      count = 0;
    }
    count++;
    last = r;
  }
  if (kind != null) {
    runs.add(_Run(kind, from, last, count));
  }
  return runs;
}

/// Null when [runs] holds a near-white run, then a green run, then a
/// near-white run, each pair separated by at most [gap] anti-aliased
/// samples; otherwise the profile for the failure message.
String? _crossingFailure(
  List<_Run> runs, {
  int minWhite = 2,
  int minGreen = 4,
}) {
  const int gap = 2;
  for (int j = 0; j < runs.length; j++) {
    if (runs[j].kind != _Kind.green || runs[j].samples < minGreen) {
      continue;
    }
    bool before = false;
    for (int i = j - 1; i >= 0; i--) {
      if (runs[i].kind == _Kind.white && runs[i].samples >= minWhite) {
        before = true;
        break;
      }
      if (runs[i].kind != _Kind.other || runs[i].samples > gap) {
        break;
      }
    }
    bool after = false;
    for (int k = j + 1; k < runs.length; k++) {
      if (runs[k].kind == _Kind.white && runs[k].samples >= minWhite) {
        after = true;
        break;
      }
      if (runs[k].kind != _Kind.other || runs[k].samples > gap) {
        break;
      }
    }
    if (before && after) {
      return null;
    }
  }
  return runs.map((_Run r) => '$r').join(' ');
}

List<double> _angles(int n, {double phase = 0}) => <double>[
  for (int i = 0; i < n; i++) phase + 2 * math.pi * i / n,
];

String _deg(double radians) => (radians * 180 / math.pi).toStringAsFixed(1);

// ---------------------------------------------------------------------------
// Board harness.
// ---------------------------------------------------------------------------

const double _boardSide = 450;

void _pin(WidgetTester tester) {
  tester.view.physicalSize = const Size(_boardSide, _boardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<int, List<int>> _yards() => <int, List<int>>{
  for (final int s in <int>[0, 1, 2, 3]) s: <int>[-1, -1, -1, -1],
};

Widget _boardHarness({
  required GlobalKey shotKey,
  required Map<int, List<int>> tokens,
  required int? mySeat,
  required Set<int> legal,
  int? autoMoveToken,
  bool reduced = true,
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
      body: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: RepaintBoundary(
            key: shotKey,
            child: LudoBoard(
              tokens: tokens,
              mySeat: mySeat,
              legal: legal,
              autoMoveToken: autoMoveToken,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The drawn ring's box, read from the board's own ring key.
Rect _ringRect(WidgetTester tester, int seat, int token) =>
    tester.getRect(find.byKey(Key('board-legal-ring-$seat-$token')));

Rect _discRect(WidgetTester tester, int seat, int token) =>
    tester.getRect(find.byKey(Key('token-$seat-$token')));

Offset _local(WidgetTester tester, Offset global) =>
    global - tester.getTopLeft(find.byType(LudoBoard));

/// Fails with the profile of every ray that is not near-white / green /
/// near-white, naming the scenario.
void _expectHaloCrossing({
  required _Shot shot,
  required Offset centre,
  required double outerRadius,
  required String scenario,
  int rays = 8,
  double phase = 0,
  int? minWhite,
}) {
  final List<String> bad = <String>[];
  for (final double a in _angles(rays, phase: phase)) {
    final List<_Run> runs = _ray(shot, centre, a, 0, outerRadius + 3);
    final String? why = minWhite == null
        ? _crossingFailure(runs)
        : _crossingFailure(runs, minWhite: minWhite);
    if (why != null) {
      bad.add('  ray ${_deg(a)} deg: $why');
    }
  }
  expect(
    bad,
    isEmpty,
    reason:
        'Expected on every one of $rays rays from the centre outward: a '
        'near-white run (${_hex(_whiteRef)} +-10), then a green run '
        '(${_hex(_greenRef)} +-10), then a near-white run, so the ring is '
        'edged on both sides (C-604 D1/D2). ${bad.length} ray(s) have no '
        'such crossing, listed as kind[from..to] in dp from the centre. '
        'Scenario: $scenario, centre $centre, search radius '
        '${(outerRadius + 3).toStringAsFixed(2)}.\n${bad.join('\n')}',
  );
}

/// The count of rays whose control pixel in the ring's edge zone is not
/// near-white: a fixture on an all-white square proves nothing about a
/// near-white edge, so each case checks it has rays that can tell.
void _expectDiscriminating({
  required _Shot control,
  required Offset centre,
  required double boxRadius,
  required String scenario,
  required int atLeast,
}) {
  int count = 0;
  for (final double a in _angles(8)) {
    bool nonWhite = false;
    for (double r = boxRadius - 1.5; r <= boxRadius + 2.5; r += 0.25) {
      final List<int> px = control.at(
        centre.dx + math.cos(a) * r,
        centre.dy + math.sin(a) * r,
      );
      if (!_near(px, _whiteRef, 10)) {
        nonWhite = true;
      }
    }
    if (nonWhite) {
      count++;
    }
  }
  expect(
    count,
    greaterThanOrEqualTo(atLeast),
    reason:
        'Fixture check, not the contract: only $count of 8 rays have a '
        'non-near-white pixel under the ring edge in the ring-less render, '
        'need $atLeast, so a near-white halo could not be told from the '
        'square under it. Scenario: $scenario.',
  );
}

void main() {
  // =========================================================================
  // (a) Legal ring in the yard, every seat.
  // =========================================================================
  group('(a) legal ring in a yard carries a near-white edge', () {
    for (final int seat in <int>[1, 0, 2, 3]) {
      testWidgets('seat $seat viewer, roll of 6, yard tokens 0 and 1 legal: '
          'near-white / green / near-white on 8 rays of each legal disc', (
        WidgetTester tester,
      ) async {
        _pin(tester);
        final GlobalKey key = GlobalKey();
        const double ratio = 4;
        final String scenario =
            'yard, viewer seat $seat, legal {0,1}, reduced motion, '
            'board $_boardSide dp, pixel ratio $ratio';
        await tester.pumpWidget(
          _boardHarness(
            shotKey: key,
            tokens: _yards(),
            mySeat: seat,
            legal: const <int>{0, 1},
          ),
        );
        await tester.pump();
        final _Shot shot = await _shoot(tester, key, ratio: ratio);

        await tester.pumpWidget(
          _boardHarness(
            shotKey: key,
            tokens: _yards(),
            mySeat: seat,
            legal: const <int>{},
          ),
        );
        await tester.pump();
        final _Shot control = await _shoot(tester, key, ratio: ratio);

        // Re-mount with the ring to read its box (the control mount has none).
        await tester.pumpWidget(
          _boardHarness(
            shotKey: key,
            tokens: _yards(),
            mySeat: seat,
            legal: const <int>{0, 1},
          ),
        );
        await tester.pump();
        for (final int token in <int>[0, 1]) {
          final Rect ring = _ringRect(tester, seat, token);
          final Offset c = _local(tester, ring.center);
          _expectDiscriminating(
            control: control,
            centre: c,
            boxRadius: ring.width / 2,
            scenario: '$scenario, token $token',
            atLeast: 8,
          );
          _expectHaloCrossing(
            shot: shot,
            centre: c,
            outerRadius: ring.width / 2,
            scenario: '$scenario, token $token',
          );
        }
      });
    }

    testWidgets('pulse peak (animations on, t = 1): the edge is there at the '
        'widest stroke too', (WidgetTester tester) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      const double ratio = 4;
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: _yards(),
          mySeat: 1,
          legal: const <int>{0},
          reduced: false,
        ),
      );
      await tester.pump();
      // The ring breathes with a 900 ms half period and reverses; the test
      // clock is fake, so this lands on the same phase every run.
      await tester.pump(const Duration(milliseconds: 900));
      final CustomPaint paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const Key('board-legal-ring-1-0')),
          matching: find.byType(CustomPaint),
        ),
      );
      final dynamic painter = paint.painter;
      final double opacity = painter.opacity as double;
      final double stroke = painter.strokeWidth as double;
      expect(
        opacity,
        greaterThan(0.999),
        reason:
            'Fixture check, not the contract: at 900 ms of a 900 ms half '
            'period the ring should be at its peak (opacity 1.0, stroke '
            '4.0); got opacity $opacity stroke $stroke.',
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      final Rect ring = _ringRect(tester, 1, 0);
      _expectHaloCrossing(
        shot: shot,
        centre: _local(tester, ring.center),
        outerRadius: ring.width / 2,
        scenario:
            'yard, viewer seat 1, legal {0}, animations on at 900 ms '
            '(opacity $opacity, stroke $stroke), pixel ratio $ratio',
      );
    });
  });

  // =========================================================================
  // (b) Legal ring on a track square, every seat.
  // =========================================================================
  group('(b) legal ring on a track square carries a near-white edge', () {
    for (final int seat in <int>[1, 0, 2, 3]) {
      testWidgets('seat $seat viewer, token at progress 1 next to its '
          'coloured start square: near-white / green / near-white on 8 rays', (
        WidgetTester tester,
      ) async {
        _pin(tester);
        final GlobalKey key = GlobalKey();
        const double ratio = 4;
        final Map<int, List<int>> tokens = _yards();
        tokens[seat] = <int>[1, -1, -1, -1];
        final String scenario =
            'track progress 1, viewer seat $seat, legal {0}, reduced '
            'motion, board $_boardSide dp, pixel ratio $ratio';
        await tester.pumpWidget(
          _boardHarness(
            shotKey: key,
            tokens: tokens,
            mySeat: seat,
            legal: const <int>{0},
          ),
        );
        await tester.pump();
        final _Shot shot = await _shoot(tester, key, ratio: ratio);
        final Rect ring = _ringRect(tester, seat, 0);
        final Offset c = _local(tester, ring.center);

        await tester.pumpWidget(
          _boardHarness(
            shotKey: key,
            tokens: tokens,
            mySeat: seat,
            legal: const <int>{},
          ),
        );
        await tester.pump();
        final _Shot control = await _shoot(tester, key, ratio: ratio);
        _expectDiscriminating(
          control: control,
          centre: c,
          boxRadius: ring.width / 2,
          scenario: scenario,
          atLeast: 1,
        );
        _expectHaloCrossing(
          shot: shot,
          centre: c,
          outerRadius: ring.width / 2,
          scenario: scenario,
        );
      });
    }
  });

  // =========================================================================
  // (c) The unique-legal countdown arc.
  // =========================================================================
  group('(c) AutoMoveArcPainter edge', () {
    Widget arcHarness(GlobalKey key, AutoMoveArcPainter painter) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: Container(
              width: 60,
              height: 60,
              color: LudoColors.seats[1],
              child: CustomPaint(painter: painter),
            ),
          ),
        ),
      );
    }

    const Offset centre = Offset(30, 30);
    // Away from the 12 o'clock seam where the round caps meet.
    final double diag = math.pi / 4;

    testWidgets('remaining 1.0: near-white / green / near-white on 4 rays', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 6;
      await tester.pumpWidget(
        arcHarness(key, const AutoMoveArcPainter(remaining: 1.0)),
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      _expectHaloCrossing(
        shot: shot,
        centre: centre,
        outerRadius: 30,
        rays: 4,
        phase: diag,
        scenario:
            'AutoMoveArcPainter(remaining: 1.0) default stroke 3.0 in a '
            '60x60 box on seats[1], pixel ratio $ratio',
      );
    });

    testWidgets('remaining 1.5 clamps to a full arc and keeps its edge', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 6;
      await tester.pumpWidget(
        arcHarness(key, const AutoMoveArcPainter(remaining: 1.5)),
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      _expectHaloCrossing(
        shot: shot,
        centre: centre,
        outerRadius: 30,
        rays: 4,
        phase: diag,
        scenario:
            'AutoMoveArcPainter(remaining: 1.5) in a 60x60 box on seats[1], '
            'pixel ratio $ratio',
      );
    });

    testWidgets('strokeWidth 6.0: the edge is 1 dp each side and the wider '
        'halo is not clipped by the 60x60 box', (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 6;
      await tester.pumpWidget(
        arcHarness(
          key,
          const AutoMoveArcPainter(remaining: 1.0, strokeWidth: 6.0),
        ),
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      _expectHaloCrossing(
        shot: shot,
        centre: centre,
        outerRadius: 30,
        rays: 4,
        phase: diag,
        minWhite: 4,
        scenario:
            'AutoMoveArcPainter(remaining: 1.0, strokeWidth: 6.0) in a '
            '60x60 box on seats[1], pixel ratio $ratio; the halo is 8 dp '
            'wide and must still fit, outer edge at most 30 dp from the '
            'centre',
      );
    });

    testWidgets('remaining 0.5: edge on the swept half, background only on '
        'the unswept half', (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 6;
      await tester.pumpWidget(
        arcHarness(key, const AutoMoveArcPainter(remaining: 0.5)),
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      // The arc starts at 12 o'clock and sweeps clockwise: the right half.
      for (final double a in <double>[-diag, diag]) {
        _expectHaloCrossing(
          shot: shot,
          centre: centre,
          outerRadius: 30,
          rays: 1,
          phase: a,
          scenario:
              'AutoMoveArcPainter(remaining: 0.5), swept right half, ray '
              '${_deg(a)} deg, pixel ratio $ratio',
        );
      }
      final List<int> bg = _rgb(LudoColors.seats[1]);
      final List<String> stray = <String>[];
      for (final double a in <double>[3 * diag, -3 * diag, math.pi]) {
        for (double r = 0; r <= 30; r += 1 / ratio) {
          final List<int> px = shot.at(
            centre.dx + math.cos(a) * r,
            centre.dy + math.sin(a) * r,
          );
          if (!_near(px, bg, 1)) {
            stray.add(
              'ray ${_deg(a)} deg r ${r.toStringAsFixed(2)}: ${_hex(px)}',
            );
            break;
          }
        }
      }
      expect(
        stray,
        isEmpty,
        reason:
            'Expected only the background ${_hex(bg)} on the unswept left '
            'half of AutoMoveArcPainter(remaining: 0.5) (the halo shares '
            'the arc\'s start and sweep, C-604 D2). Found paint at: '
            '${stray.join('; ')}. Pixel ratio $ratio.',
      );
    });

    for (final double remaining in <double>[0.0, -0.5]) {
      testWidgets('remaining $remaining paints nothing but the background', (
        WidgetTester tester,
      ) async {
        final GlobalKey key = GlobalKey();
        const double ratio = 4;
        await tester.pumpWidget(
          arcHarness(key, AutoMoveArcPainter(remaining: remaining)),
        );
        final _Shot shot = await _shoot(tester, key, ratio: ratio);
        final List<int> bg = _rgb(LudoColors.seats[1]);
        int off = 0;
        String first = '';
        for (int y = 0; y < shot.height; y++) {
          for (int x = 0; x < shot.width; x++) {
            final List<int> px = shot.at((x + 0.5) / ratio, (y + 0.5) / ratio);
            if (!_near(px, bg, 0)) {
              if (off == 0) {
                first = 'pixel ($x, $y) is ${_hex(px)}';
              }
              off++;
            }
          }
        }
        expect(
          off,
          0,
          reason:
              'Expected every pixel to be the background ${_hex(bg)} for '
              'AutoMoveArcPainter(remaining: $remaining), halo included '
              '(C-604 D2: nothing is drawn at or below zero). $off pixels '
              'differ, first: $first. Pixel ratio $ratio.',
        );
      });
    }

    test(
      'public surface is unchanged: constructor, remaining, strokeWidth',
      () {
        const AutoMoveArcPainter p = AutoMoveArcPainter(
          remaining: 0.25,
          strokeWidth: 5.0,
        );
        expect(p.remaining, 0.25, reason: 'C-604 D2 keeps the remaining field');
        expect(
          p.strokeWidth,
          5.0,
          reason: 'C-604 D2 keeps the strokeWidth field',
        );
        expect(
          const AutoMoveArcPainter(remaining: 1.0).strokeWidth,
          3.0,
          reason: 'C-604 D2 keeps the default strokeWidth of 3.0',
        );
      },
    );
  });

  // =========================================================================
  // (d) The captured mark.
  // =========================================================================
  group('(d) CapturedFlashMark ring edge', () {
    const double side = 40;
    const double canvas = 120;
    const Offset centre = Offset(canvas / 2, canvas / 2);
    // Base ring: a circle border of max(2, side * 0.1) inside the scaled box.
    final double ringWidth = math.max(2.0, side * 0.1);

    Widget markHarness(GlobalKey key, Widget mark, Color background) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: canvas,
              height: canvas,
              child: ColoredBox(
                color: background,
                child: Center(
                  child: SizedBox(
                    key: const Key('c604-disc-box'),
                    width: side,
                    height: side,
                    child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: LudoColors.seats[0],
                          ),
                        ),
                        mark,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final Map<String, CapturedFlashMark Function()> marks =
        <String, CapturedFlashMark Function()>{
          'lingering(v: 0)': () => CapturedFlashMark.lingering(v: 0),
          'lingering(v: 0.5)': () => CapturedFlashMark.lingering(v: 0.5),
          'inFlight(u: 0)': () => CapturedFlashMark.inFlight(u: 0),
          'inFlight(u: 0.5)': () => CapturedFlashMark.inFlight(u: 0.5),
          'inFlight(u: 1)': () => CapturedFlashMark.inFlight(u: 1),
        };
    final Map<String, Color> backgrounds = <String, Color>{
      'dark ink': LudoColors.ink,
      'seat 0 red': LudoColors.seats[0],
    };

    Future<void> checkMark(
      WidgetTester tester, {
      required String label,
      required Color bgColor,
      required String bgName,
      required Widget mark,
      required double tintAlpha,
      required double s,
      required double o,
      required Widget Function(double tintAlpha, double s) invisible,
    }) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 6;
      await tester.pumpWidget(markHarness(key, mark, bgColor));
      final _Shot shot = await _shoot(tester, key, ratio: ratio);

      // The same mark with an invisible ring: the tint and what is
      // under it, so "under the ring" is measured, not assumed.
      await tester.pumpWidget(
        markHarness(key, invisible(tintAlpha, s), bgColor),
      );
      final _Shot under = await _shoot(tester, key, ratio: ratio);
      final double outer = side / 2 * s;
      final double inner = outer - ringWidth * s;
      final List<int> red = _rgb(LudoColors.error);
      final String scenario =
          '$label (tintAlpha ${tintAlpha.toStringAsFixed(3)}, '
          'ringScale ${s.toStringAsFixed(3)}, ringOpacity '
          '${o.toStringAsFixed(3)}) in a $side dp box on $bgName, '
          'pixel ratio $ratio';
      final List<String> bad = <String>[];
      for (final double a in _angles(8)) {
        Offset at(double r) => centre + Offset(math.cos(a), math.sin(a)) * r;
        List<int> px(_Shot sh, double r) => sh.at(at(r).dx, at(r).dy);
        List<double> asD(List<int> v) => v.map((int e) => e * 1.0).toList();

        // Red band: three samples inside it.
        for (final double f in <double>[1, 2, 3]) {
          final double r = outer - f * s;
          final List<double> base = asD(px(under, r));
          final List<double> haloed = _over(_whiteRef, o, base);
          final List<double> withHalo = _over(red, o, haloed);
          final List<double> bare = _over(red, o, base);
          final List<int> got = px(shot, r);
          if (!_nearD(got, withHalo, 12) && !_nearD(got, bare, 12)) {
            bad.add(
              'ray ${_deg(a)} deg r ${r.toStringAsFixed(2)} (band): got '
              '${_hex(got)}, wanted error ${_hex(red)} at $o over the '
              'base, ~${_hex(bare.map((double e) => e.round()).toList())}'
              ' or over the halo, '
              '~${_hex(withHalo.map((double e) => e.round()).toList())}',
            );
          }
        }

        // Edge windows, each a quarter to one and a quarter of the
        // scaled dp beyond the band.
        bool edge(double from, double to) {
          for (double r = from; r <= to; r += 1 / ratio) {
            final List<double> expected = _over(
              _whiteRef,
              o,
              asD(px(under, r)),
            );
            if (_nearD(px(shot, r), expected, 12)) {
              return true;
            }
          }
          return false;
        }

        if (!edge(inner - 1.25 * s, inner - 0.25 * s)) {
          bad.add(
            'ray ${_deg(a)} deg: no near-white pixel (actionOn at $o) '
            'between r ${(inner - 1.25 * s).toStringAsFixed(2)} and '
            '${(inner - 0.25 * s).toStringAsFixed(2)}, just inside the '
            'band\'s inner edge at ${inner.toStringAsFixed(2)}',
          );
        }
        if (!edge(outer + 0.25 * s, outer + 1.25 * s)) {
          bad.add(
            'ray ${_deg(a)} deg: no near-white pixel (actionOn at $o) '
            'between r ${(outer + 0.25 * s).toStringAsFixed(2)} and '
            '${(outer + 1.25 * s).toStringAsFixed(2)}, just outside the '
            'band\'s outer edge at ${outer.toStringAsFixed(2)}',
          );
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Expected the red ring band to read as error at ringOpacity '
            'with a near-white edge on both sides (C-604 D3). '
            'Scenario: $scenario.\n${bad.join('\n')}',
      );
    }

    for (final MapEntry<String, CapturedFlashMark Function()> entry
        in marks.entries) {
      for (final MapEntry<String, Color> bg in backgrounds.entries) {
        testWidgets('${entry.key} over a seats[0] disc on ${bg.key}: red band '
            'with a near-white edge inside and outside, on 8 rays', (
          WidgetTester tester,
        ) async {
          final CapturedFlashMark mark = entry.value();
          await checkMark(
            tester,
            label: entry.key,
            bgColor: bg.value,
            bgName: bg.key,
            mark: mark,
            tintAlpha: mark.tintAlpha,
            s: mark.ringScale,
            o: mark.ringOpacity,
            invisible: (double t, double s) =>
                CapturedFlashMark(tintAlpha: t, ringScale: s, ringOpacity: 0.0),
          );
        });
      }
    }

    testWidgets('lingering(v: 1): nothing of the ring or the tint is left', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      const double ratio = 4;
      await tester.pumpWidget(
        markHarness(key, CapturedFlashMark.lingering(v: 1), LudoColors.ink),
      );
      final _Shot withMark = await _shoot(tester, key, ratio: ratio);
      await tester.pumpWidget(
        markHarness(key, const SizedBox.shrink(), LudoColors.ink),
      );
      final _Shot without = await _shoot(tester, key, ratio: ratio);
      int off = 0;
      String first = '';
      for (int y = 0; y < withMark.height; y++) {
        for (int x = 0; x < withMark.width; x++) {
          final List<int> a = withMark.at((x + 0.5) / ratio, (y + 0.5) / ratio);
          final List<int> b = without.at((x + 0.5) / ratio, (y + 0.5) / ratio);
          if (!_near(a, b, 0)) {
            if (off == 0) {
              first = 'pixel ($x, $y) is ${_hex(a)}, wanted ${_hex(b)}';
            }
            off++;
          }
        }
      }
      expect(
        off,
        0,
        reason:
            'Expected CapturedFlashMark.lingering(v: 1) to leave the image '
            'identical to the same scene with no mark (ringOpacity 0 means '
            'the halo is gone too, C-604 D3). $off pixels differ, first: '
            '$first. Pixel ratio $ratio.',
      );
    });

    testWidgets('public surface is unchanged: constructors and fields', (
      WidgetTester tester,
    ) async {
      const CapturedFlashMark direct = CapturedFlashMark(
        tintAlpha: 0.3,
        ringScale: 1.2,
        ringOpacity: 0.7,
      );
      expect(direct.tintAlpha, 0.3, reason: 'C-604 D3 keeps tintAlpha');
      expect(direct.ringScale, 1.2, reason: 'C-604 D3 keeps ringScale');
      expect(direct.ringOpacity, 0.7, reason: 'C-604 D3 keeps ringOpacity');
      final CapturedFlashMark flight = CapturedFlashMark.inFlight(u: 0);
      final CapturedFlashMark linger = CapturedFlashMark.lingering(v: 0);
      expect(
        flight.ringOpacity,
        1.0,
        reason:
            'C-604 D3 keeps the named inFlight constructor: opacity 1.0 '
            'at take-off',
      );
      expect(
        linger.ringOpacity,
        lessThan(flight.ringOpacity),
        reason:
            'C-604 D3 keeps the named lingering constructor: the ring '
            'starts fainter than take-off',
      );
    });
  });

  // =========================================================================
  // (e) Geometry unchanged, and nothing painted where there is no ring.
  // =========================================================================
  group('(e) geometry unchanged, nothing painted without a ring', () {
    testWidgets('legal ring box: 1.7x the disc, centred on it, same key', (
      WidgetTester tester,
    ) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      final Map<int, List<int>> tokens = _yards();
      tokens[1] = <int>[1, -1, -1, -1];
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{0, 1},
        ),
      );
      await tester.pump();
      for (final int token in <int>[0, 1]) {
        final Rect disc = _discRect(tester, 1, token);
        final Rect ring = _ringRect(tester, 1, token);
        expect(
          ring.width,
          closeTo(disc.width * 1.7, 0.01),
          reason:
              'Expected board-legal-ring-1-$token to stay 1.7x the disc '
              '(C-604 D1: size unchanged); disc ${disc.width}, ring '
              '${ring.width}.',
        );
        expect(
          ring.height,
          closeTo(ring.width, 0.01),
          reason: 'Expected a square ring box for token $token.',
        );
        expect(
          (ring.center - disc.center).distance,
          lessThan(0.5),
          reason:
              'Expected board-legal-ring-1-$token centred on its disc '
              '(C-604 D1: centre unchanged); ring ${ring.center}, disc '
              '${disc.center}.',
        );
      }
    });

    testWidgets('unique-legal glow: the arc box clears the ring by the same '
        '12 dp', (WidgetTester tester) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      final Map<int, List<int>> tokens = _yards();
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{0},
          autoMoveToken: 0,
        ),
      );
      await tester.pump();
      final Rect disc = _discRect(tester, 1, 0);
      final Rect box = _ringRect(tester, 1, 0);
      final Rect arc = tester.getRect(
        find.byKey(const Key('board-automove-arc-1-0')),
      );
      expect(
        arc.width,
        closeTo(disc.width * 1.7 + 12, 0.01),
        reason:
            'Expected board-automove-arc-1-0 to stay the ring size plus '
            '12 dp (C-604 D2/D4: no size changes); disc ${disc.width}, arc '
            '${arc.width}.',
      );
      expect(
        box.width,
        closeTo(arc.width, 0.01),
        reason: 'Expected the legal-ring key to wrap the arc box unchanged.',
      );
      expect(
        (arc.center - disc.center).distance,
        lessThan(0.5),
        reason:
            'Expected the arc centred on its disc; arc ${arc.center}, '
            'disc ${disc.center}.',
      );
    });

    testWidgets('painted ring stays centred on the box and its outer edge '
        'stays at the box radius (inside -0.5 dp, outside +1 dp)', (
      WidgetTester tester,
    ) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      const double ratio = 4;
      final Map<int, List<int>> tokens = _yards();
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{0},
        ),
      );
      await tester.pump();
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      final Rect ring = _ringRect(tester, 1, 0);
      final Offset c = _local(tester, ring.center);
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{},
        ),
      );
      await tester.pump();
      final _Shot control = await _shoot(tester, key, ratio: ratio);
      final double boxR = ring.width / 2;
      final List<String> bad = <String>[];
      for (final double a in _angles(8)) {
        double? outermost;
        for (double r = 0; r <= boxR + 6; r += 1 / ratio) {
          final double x = c.dx + math.cos(a) * r;
          final double y = c.dy + math.sin(a) * r;
          if (!_near(shot.at(x, y), control.at(x, y), 0)) {
            outermost = r;
          }
        }
        if (outermost == null ||
            outermost < boxR - 0.5 - 0.5 ||
            outermost > boxR + 1.0 + 0.5) {
          bad.add(
            'ray ${_deg(a)} deg: outermost painted radius '
            '${outermost?.toStringAsFixed(2)}',
          );
        }
      }
      expect(
        bad,
        isEmpty,
        reason:
            'Expected the outermost pixel the ring adds on each ray to lie '
            'between ${(boxR - 1.0).toStringAsFixed(2)} and '
            '${(boxR + 1.5).toStringAsFixed(2)} dp from the disc centre '
            '(box radius ${boxR.toStringAsFixed(2)}; C-604 D1: size and '
            'centre unchanged). Scenario: yard, viewer seat 1, legal {0}, '
            'reduced motion, pixel ratio $ratio.\n${bad.join('\n')}',
      );
    });

    testWidgets('a ring paints only inside its own box: the rest of the '
        'board is pixel-identical to the ring-less render', (
      WidgetTester tester,
    ) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      const double ratio = 2;
      final Map<int, List<int>> tokens = _yards();
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{0, 1},
        ),
      );
      await tester.pump();
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      final List<Rect> boxes = <Rect>[
        for (final int t in <int>[0, 1])
          _ringRect(
            tester,
            1,
            t,
          ).shift(-tester.getTopLeft(find.byType(LudoBoard))),
      ];
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: 1,
          legal: const <int>{},
        ),
      );
      await tester.pump();
      final _Shot control = await _shoot(tester, key, ratio: ratio);
      int stray = 0;
      String first = '';
      for (int y = 0; y < shot.height; y++) {
        for (int x = 0; x < shot.width; x++) {
          final double px = (x + 0.5) / ratio;
          final double py = (y + 0.5) / ratio;
          if (!_near(shot.at(px, py), control.at(px, py), 0)) {
            final bool inside = boxes.any(
              (Rect b) => b.inflate(1.5).contains(Offset(px, py)),
            );
            if (!inside) {
              if (stray == 0) {
                first = 'dp ($px, $py)';
              }
              stray++;
            }
          }
        }
      }
      expect(
        stray,
        0,
        reason:
            'Expected legal rings to change no pixel outside their own '
            'boxes plus 1.5 dp (C-604 D4: nothing else changes). $stray '
            'pixels differ elsewhere, first at $first. Scenario: yard, '
            'viewer seat 1, legal {0,1} against legal {}, reduced motion, '
            'pixel ratio $ratio.',
      );
    });

    testWidgets('spectator with a legal set paints nothing extra: identical '
        'to the same board with no legal set', (WidgetTester tester) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      const double ratio = 2;
      final Map<int, List<int>> tokens = _yards();
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: null,
          legal: const <int>{0, 1},
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('board-legal-ring-1-0')),
        findsNothing,
        reason: 'A spectator board has no legal ring.',
      );
      final _Shot shot = await _shoot(tester, key, ratio: ratio);
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: tokens,
          mySeat: null,
          legal: const <int>{},
        ),
      );
      await tester.pump();
      final _Shot control = await _shoot(tester, key, ratio: ratio);
      int off = 0;
      String first = '';
      for (int y = 0; y < shot.height; y++) {
        for (int x = 0; x < shot.width; x++) {
          final double px = (x + 0.5) / ratio;
          final double py = (y + 0.5) / ratio;
          if (!_near(shot.at(px, py), control.at(px, py), 0)) {
            if (off == 0) {
              first = 'dp ($px, $py)';
            }
            off++;
          }
        }
      }
      expect(
        off,
        0,
        reason:
            'Expected no halo and no ring on a spectator board (C-604: the '
            'halo exists only with a ring). $off pixels differ, first at '
            '$first. Scenario: mySeat null, legal {0,1} against legal {}, '
            'pixel ratio $ratio.',
      );
    });

    testWidgets('a legal set is read for the viewer\'s seat only: no ring, '
        'so no halo, on any other seat', (WidgetTester tester) async {
      _pin(tester);
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        _boardHarness(
          shotKey: key,
          tokens: _yards(),
          mySeat: 1,
          legal: const <int>{0, 1},
        ),
      );
      await tester.pump();
      final List<String> found = <String>[];
      for (final int seat in <int>[0, 1, 2, 3]) {
        for (final int token in <int>[0, 1, 2, 3]) {
          final bool present = find
              .byKey(Key('board-legal-ring-$seat-$token'))
              .evaluate()
              .isNotEmpty;
          final bool wanted = seat == 1 && token <= 1;
          if (present != wanted) {
            found.add('seat $seat token $token present=$present');
          }
        }
      }
      expect(
        found,
        isEmpty,
        reason:
            'Expected rings for seat 1 tokens 0 and 1 only (viewer seat 1, '
            'legal {0,1}); unexpected: ${found.join('; ')}.',
      );
    });

    testWidgets('captured mark box equals the disc box', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 120,
                height: 120,
                child: Center(
                  child: SizedBox(
                    key: const Key('c604-disc-box'),
                    width: 40,
                    height: 40,
                    child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        const DecoratedBox(
                          decoration: BoxDecoration(shape: BoxShape.circle),
                        ),
                        CapturedFlashMark.lingering(v: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final Rect disc = tester.getRect(find.byKey(const Key('c604-disc-box')));
      final Rect mark = tester.getRect(find.byType(CapturedFlashMark));
      expect(
        mark,
        disc,
        reason:
            'Expected CapturedFlashMark to fill exactly the disc\'s box '
            '(C-604 D3: centred identically, no size change); disc $disc, '
            'mark $mark. Scenario: lingering(v: 0) in a 40x40 box.',
      );
    });
  });

  // =========================================================================
  // Oracle: the checks above accept a drawing built straight from the
  // contract text. Without these, a red run could mean a mis-set threshold
  // instead of a missing halo. The painters below are written from D1, D2
  // and D3 here, not taken from lib/.
  // =========================================================================
  group('oracle: reference drawings of D1, D2 and D3 pass the same checks', () {
    testWidgets('D1 reference ring, steady 3.5 dp and the 2.0 dp trough', (
      WidgetTester tester,
    ) async {
      const double ratio = 4;
      const double box = 35.7;
      for (final double stroke in <double>[3.5, 2.0]) {
        final GlobalKey key = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 60,
                  height: 60,
                  child: ColoredBox(
                    color: LudoColors.seats[1],
                    child: Center(
                      child: SizedBox(
                        width: box,
                        height: box,
                        child: CustomPaint(painter: _RefRing(stroke)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final _Shot shot = await _shoot(tester, key, ratio: ratio);
        _expectHaloCrossing(
          shot: shot,
          centre: const Offset(30, 30),
          outerRadius: box / 2,
          minWhite: 3,
          scenario: 'reference D1 ring, stroke $stroke, pixel ratio $ratio',
        );
      }
    });

    testWidgets('D2 reference arc, full, half and 6 dp', (
      WidgetTester tester,
    ) async {
      const double ratio = 6;
      for (final (double remaining, double stroke) in <(double, double)>[
        (1.0, 3.0),
        (1.0, 6.0),
        (0.5, 3.0),
      ]) {
        final GlobalKey key = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: key,
                child: Container(
                  width: 60,
                  height: 60,
                  color: LudoColors.seats[1],
                  child: CustomPaint(painter: _RefArc(remaining, stroke)),
                ),
              ),
            ),
          ),
        );
        final _Shot shot = await _shoot(tester, key, ratio: ratio);
        _expectHaloCrossing(
          shot: shot,
          centre: const Offset(30, 30),
          outerRadius: 30,
          rays: 1,
          phase: math.pi / 4,
          minWhite: stroke > 5 ? 4 : null,
          scenario:
              'reference D2 arc, remaining $remaining, stroke $stroke, '
              'pixel ratio $ratio',
        );
      }
    });

    for (final (double tint, double scale, double opacity)
        in <(double, double, double)>[
          (0.45, 1.85, 0.65),
          (0.45, 1.15, 1.0),
          (0.2, 1.5, 0.8),
        ]) {
      testWidgets('D3 reference mark, scale $scale opacity $opacity', (
        WidgetTester tester,
      ) async {
        const double ratio = 6;
        const double canvas = 120;
        const double side = 40;
        final double ringWidth = math.max(2.0, side * 0.1);
        final GlobalKey key = GlobalKey();
        Widget scene(Widget mark) => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: canvas,
                height: canvas,
                child: ColoredBox(
                  color: LudoColors.ink,
                  child: Center(
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: LudoColors.seats[0],
                            ),
                          ),
                          mark,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(scene(_RefMark(tint, scale, opacity)));
        final _Shot shot = await _shoot(tester, key, ratio: ratio);
        await tester.pumpWidget(scene(_RefMark(tint, scale, 0.0)));
        final _Shot under = await _shoot(tester, key, ratio: ratio);

        final double outer = side / 2 * scale;
        final double inner = outer - ringWidth * scale;
        final List<int> red = _rgb(LudoColors.error);
        const Offset c = Offset(canvas / 2, canvas / 2);
        final List<String> bad = <String>[];
        for (final double a in _angles(8)) {
          List<double> d(_Shot sh, double r) => sh
              .at(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r)
              .map((int e) => e * 1.0)
              .toList();
          List<int> i(_Shot sh, double r) =>
              sh.at(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
          final double rb = outer - 2 * scale;
          final List<double> want = _over(
            red,
            opacity,
            _over(_whiteRef, opacity, d(under, rb)),
          );
          if (!_nearD(i(shot, rb), want, 12)) {
            bad.add('ray ${_deg(a)} band got ${_hex(i(shot, rb))}');
          }
          bool edge(double from, double to) {
            for (double r = from; r <= to; r += 1 / ratio) {
              if (_nearD(
                i(shot, r),
                _over(_whiteRef, opacity, d(under, r)),
                12,
              )) {
                return true;
              }
            }
            return false;
          }

          if (!edge(inner - 1.25 * scale, inner - 0.25 * scale)) {
            bad.add('ray ${_deg(a)} no inner edge');
          }
          if (!edge(outer + 0.25 * scale, outer + 1.25 * scale)) {
            bad.add('ray ${_deg(a)} no outer edge');
          }
        }
        expect(
          bad,
          isEmpty,
          reason:
              'The reference D3 mark (tint $tint, scale $scale, opacity '
              '$opacity) must satisfy the edge checks; if it does not the '
              'check is wrong, not the implementation: ${bad.join('; ')}',
        );
      });
    }
  });
}

/// D1 written from the contract: an actionOn stroke of strokeWidth + 2.0
/// on the same oval, then the coloured stroke, both deflated by half the
/// halo width so nothing leaves the box.
class _RefRing extends CustomPainter {
  const _RefRing(this.strokeWidth);

  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate((strokeWidth + 2.0) / 2);
    canvas.drawOval(
      rect,
      Paint()
        ..color = LudoColors.actionOn
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 2.0,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = LudoColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _RefRing oldDelegate) => false;
}

/// D2 written from the contract: the same arc twice, the wider one in
/// actionOn underneath, round caps, deflated by half the halo width.
class _RefArc extends CustomPainter {
  const _RefArc(this.remaining, this.strokeWidth);

  final double remaining;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate((strokeWidth + 2.0) / 2);
    final double sweep = remaining.clamp(0.0, 1.0) * 2 * math.pi;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = LudoColors.actionOn
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 2.0
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = LudoColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RefArc oldDelegate) => false;
}

/// D3 written from the contract: the tint, then under the red-bordered
/// circle a circle bordered in actionOn two dp wider, both at ringOpacity,
/// both under the same scale.
class _RefMark extends StatelessWidget {
  const _RefMark(this.tintAlpha, this.ringScale, this.ringOpacity);

  final double tintAlpha;
  final double ringScale;
  final double ringOpacity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: LudoColors.error.withValues(alpha: tintAlpha),
          ),
        ),
        Transform.scale(
          scale: ringScale,
          child: CustomPaint(painter: _RefMarkRing(ringOpacity)),
        ),
      ],
    );
  }
}

class _RefMarkRing extends CustomPainter {
  const _RefMarkRing(this.opacity);

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final double width = math.max(2.0, size.shortestSide * 0.1);
    final Rect rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawOval(
      rect,
      Paint()
        ..color = LudoColors.actionOn.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 2.0,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = LudoColors.error.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(covariant _RefMarkRing oldDelegate) =>
      oldDelegate.opacity != opacity;
}
