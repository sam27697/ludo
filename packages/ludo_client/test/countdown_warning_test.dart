// Screen proof for work/ludo/orders/586-watcher-dead-roll-countdown-warning.md,
// D6 and D7: the last seconds of a turn read without colour. Written from the
// contract alone, against a GameScreen over a real RoomController on
// FakeTransport (test/support/roll_tray_harness.dart). Time moves only by
// tester.pump(duration); a live countdown never meets pumpAndSettle.
//
// The window is the existing `runningOut` condition, thresholds unchanged:
// the last 10 s of a segment, the last 3 s of a 10 s segment. The cases read
// it the way test/countdown_segment_test.dart pins it (a 45 s segment is red
// at 10 s left and not at 11; a 10 s segment is red at 3 s left and not at 4).
//
// Reading the beat. The contract names the wrapper (key
// game-header-countdown-warning) and says it scales 1.0 to 1.15 and back over
// 300 ms, but not which widget does the scaling. The cases therefore read the
// scale off the render tree, which holds whatever the implementation picks
// (Transform, ScaleTransition): the ring's transform to the root,
// RenderObject.getTransformTo(null), divided by the same transform measured
// before the window opens. A layout change would show in tester.getSize of
// the ring and of the wrapper, which the cases also pin.
//
// Reading the stroke. The ring exposes only its colour and its remaining
// fraction. D6(a) (stroke twice as wide) is read from pixels: a frame of the
// ring is captured at 4x, the outermost band of ring-coloured pixels is
// found in a radial histogram around the ring's centre, and its thickness is
// compared inside and outside the window. The digits' own box is left out of
// the histogram (the test font draws it as a solid block that reaches the
// ring's band), and the band is followed inwards only while it stays
// contiguous.
//
// Every failure reason names the scenario and ends with the pumps that led to
// it. The cases are deterministic, so the scenario is the whole
// reproduction; there is no seed.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/roll_tray_harness.dart';

const Key _ringKey = Key('game-header-countdown-ring');
const Key _digitsKey = Key('game-screen-turn-countdown');
const Key _timeUpKey = Key('game-screen-turn-timeup');
const Key _warningKey = Key('game-header-countdown-warning');
const Key _shotKey = Key('countdown-warning-shot');

class _Scn {
  _Scn(this.name, this.tester);

  final String name;
  final WidgetTester tester;
  final List<String> steps = <String>[];
  int clockMs = 0;

  String why(String expected) =>
      '$name | expected: $expected | at ${clockMs}ms | replay: '
      '${steps.join(' > ')}';

  /// Pumps [ms] as one pump (a timer due inside it fires, the frame after it
  /// shows the new second).
  Future<void> pumpOnce(int ms) async {
    steps.add('pump ${ms}ms');
    await tester.pump(Duration(milliseconds: ms));
    clockMs += ms;
  }

  /// Pumps [ms] in 16 ms frames (the last one shorter), calling [onFrame]
  /// with the milliseconds elapsed in this call after each frame.
  Future<void> pumpFrames(int ms, {void Function(int elapsed)? onFrame}) async {
    steps.add('pump ${ms}ms in frames');
    int elapsed = 0;
    while (elapsed < ms) {
      final int step = math.min(16, ms - elapsed);
      await tester.pump(Duration(milliseconds: step));
      elapsed += step;
      clockMs += step;
      onFrame?.call(elapsed);
    }
  }
}

Map<String, Object?> _turn({
  required int seat,
  required int deadlineMs,
  required int segmentMs,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': deadlineMs,
  'k': 0,
  'segment_ms': segmentMs,
  'queue': const <int>[],
};

Future<RollTrayDrive> _mount(
  WidgetTester tester, {
  required int mySeat,
  required int turnSeat,
  required int deadlineMs,
  required int segmentMs,
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final RollTrayDrive drive = await connectPlaying(
    tester,
    mySeat: mySeat,
    turn: _turn(seat: turnSeat, deadlineMs: deadlineMs, segmentMs: segmentMs),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: rollTrayHarness(
        FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: drive.feedback,
          child: GameScreen(controller: drive.controller),
        ),
        locale: locale,
        disableAnimations: disableAnimations,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(_ringKey),
    findsOneWidget,
    reason: 'fixture: game-header-countdown-ring is on screen',
  );
  return drive;
}

// --- reading the screen ------------------------------------------------------

bool _warning(WidgetTester tester) => tester.any(find.byKey(_warningKey));

int? _shownSeconds(WidgetTester tester) {
  final Finder f = find.byKey(_digitsKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final Widget w = tester.widget(f);
  final String? data = w is Text
      ? (w.data ?? w.textSpan?.toPlainText())
      : tester
            .widget<Text>(
              find.descendant(of: f, matching: find.byType(Text)).first,
            )
            .data;
  final Match? m = RegExp(r'\d+').firstMatch(data ?? '');
  return m == null ? null : int.parse(m.group(0)!);
}

FontWeight? _digitsWeight(WidgetTester tester) {
  final Finder f = find.byKey(_digitsKey);
  final Element element = f.evaluate().single;
  final Widget w = element.widget;
  final Text text = w is Text
      ? w
      : tester.widget<Text>(
          find.descendant(of: f, matching: find.byType(Text)).first,
        );
  final TextStyle merged = DefaultTextStyle.of(element).style.merge(text.style);
  return merged.fontWeight;
}

/// The render object whose cumulative transform stands for the countdown:
/// the ring while it is drawn, the time-up hourglass otherwise.
RenderObject _countdownRender(WidgetTester tester) {
  if (tester.any(find.byKey(_ringKey))) {
    return tester.renderObject(find.byKey(_ringKey));
  }
  return tester.renderObject(find.byKey(_timeUpKey));
}

/// The uniform scale part of the cumulative paint transform of [render].
double _scaleOf(RenderObject render) {
  final Matrix4 m = render.getTransformTo(null);
  final double x = m.storage[0];
  final double y = m.storage[1];
  return math.sqrt(x * x + y * y);
}

Size _ringSize(WidgetTester tester) => tester.getSize(find.byKey(_ringKey));

// --- stroke thickness from pixels --------------------------------------------

double _distance(Color a, Color b) {
  final double dr = a.r - b.r;
  final double dg = a.g - b.g;
  final double db = a.b - b.b;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

/// Thickness in logical pixels of the outermost band of ring-coloured pixels.
Future<double> _strokeThickness(_Scn s) async {
  final WidgetTester tester = s.tester;
  const double ratio = 4;
  final Rect box = tester.getRect(find.byKey(_ringKey));
  final dynamic ring = tester.widget(find.byKey(_ringKey));
  final Color ringColor = ring.color as Color;
  final Rect digits = tester.getRect(find.byKey(_digitsKey));
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  final ui.Image image = (await tester.runAsync<ui.Image>(
    () => boundary.toImage(pixelRatio: ratio),
  ))!;
  final ByteData? raw = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final ByteData data = raw!;
  Color at(int px, int py) {
    final int x = px.clamp(0, image.width - 1);
    final int y = py.clamp(0, image.height - 1);
    final int i = (y * image.width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  final Color background = at(
    ((box.left + 0.5) * ratio).round(),
    ((box.top + 0.5) * ratio).round(),
  );
  final double span = _distance(ringColor, background);
  expect(
    span,
    greaterThan(0.2),
    reason: s.why(
      'fixture: the ring colour $ringColor is distinguishable from the '
      'background $background',
    ),
  );
  final Offset centre = box.center;
  final double radius = math.min(box.width, box.height) / 2;
  const double binWidth = 0.25;
  final int bins = ((radius + 4) / binWidth).ceil();
  final List<bool> strong = List<bool>.filled(bins, false);
  final int x0 = ((centre.dx - radius - 4) * ratio).floor();
  final int x1 = ((centre.dx + radius + 4) * ratio).ceil();
  final int y0 = ((centre.dy - radius - 4) * ratio).floor();
  final int y1 = ((centre.dy + radius + 4) * ratio).ceil();
  for (int py = y0; py <= y1; py++) {
    for (int px = x0; px <= x1; px++) {
      final double r = math.sqrt(
        math.pow(px / ratio - centre.dx, 2) +
            math.pow(py / ratio - centre.dy, 2),
      );
      final int bin = (r / binWidth).floor();
      if (bin < 0 || bin >= bins) {
        continue;
      }
      if (digits.inflate(1).contains(Offset(px / ratio, py / ratio))) {
        continue;
      }
      if (px / ratio < box.left ||
          px / ratio > box.right ||
          py / ratio < box.top ||
          py / ratio > box.bottom) {
        continue;
      }
      if (_distance(at(px, py), ringColor) / span < 0.35) {
        strong[bin] = true;
      }
    }
  }
  int outer = -1;
  for (int i = bins - 1; i >= 0; i--) {
    if (strong[i]) {
      outer = i;
      break;
    }
  }
  expect(
    outer,
    isNot(-1),
    reason: s.why('fixture: some ring-coloured pixels are on screen'),
  );
  int inner = outer;
  while (inner > 0 && strong[inner - 1]) {
    inner -= 1;
  }
  return (outer - inner + 1) * binWidth;
}

void main() {
  // ===========================================================================
  // (j): the window on a 45 s segment.
  // ===========================================================================
  testWidgets('C-586 D6 (j): 45 s segment: no wrapper at 11 s left, wrapper '
      'and w800 digits at 10 s', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 12000,
      segmentMs: 45000,
    );
    final _Scn s = _Scn('45s segment, seat 1 on turn, 12 s left', tester);
    try {
      expect(_shownSeconds(tester), 12, reason: s.why('fixture: 12 shown'));
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('no game-header-countdown-warning at 12 s left'),
      );
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 11, reason: s.why('fixture: 11 shown'));
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('no game-header-countdown-warning at 11 s left'),
      );
      expect(
        _digitsWeight(tester),
        isNot(FontWeight.w800),
        reason: s.why('digits are not w800 outside the window'),
      );
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 10, reason: s.why('fixture: 10 shown'));
      expect(
        find.byKey(_warningKey),
        findsOneWidget,
        reason: s.why('game-header-countdown-warning exists at 10 s left'),
      );
      expect(
        _digitsWeight(tester),
        FontWeight.w800,
        reason: s.why('digits are FontWeight.w800 at 10 s left'),
      );
      expect(
        find.descendant(
          of: find.byKey(_warningKey),
          matching: find.byKey(_ringKey),
        ),
        findsOneWidget,
        reason: s.why('the ring sits under the wrapper'),
      );
      expect(
        find.descendant(
          of: find.byKey(_warningKey),
          matching: find.byKey(_digitsKey),
        ),
        findsOneWidget,
        reason: s.why('the digits sit under the wrapper'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // (k): the window on a 10 s segment.
  // ===========================================================================
  testWidgets('C-586 D6 (k): 10 s segment: no wrapper at 4 s left, wrapper '
      'at 3 s', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 10000,
      segmentMs: 10000,
    );
    final _Scn s = _Scn('10s segment, seat 1 on turn, 10 s left', tester);
    try {
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('no wrapper at 10 s left of a 10 s segment'),
      );
      await s.pumpOnce(6000);
      expect(_shownSeconds(tester), 4, reason: s.why('fixture: 4 shown'));
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('no wrapper at 4 s left of a 10 s segment'),
      );
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 3, reason: s.why('fixture: 3 shown'));
      expect(
        find.byKey(_warningKey),
        findsOneWidget,
        reason: s.why('the wrapper exists at 3 s left of a 10 s segment'),
      );
      expect(
        _digitsWeight(tester),
        FontWeight.w800,
        reason: s.why('digits are w800 at 3 s left'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // (l): seat 0's own turn, the red-on-red case.
  // ===========================================================================
  testWidgets('C-586 D6 (l): my turn as seat 0 (seat colour and error are '
      'both red): the wrapper exists in the window', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 0,
      deadlineMs: 12000,
      segmentMs: 45000,
    );
    final _Scn s = _Scn('45s segment, seat 0 (me) on turn, 12 s left', tester);
    try {
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('no wrapper at 12 s left'),
      );
      await s.pumpOnce(2000);
      expect(_shownSeconds(tester), 10, reason: s.why('fixture: 10 shown'));
      expect(
        find.byKey(_warningKey),
        findsOneWidget,
        reason: s.why('the wrapper exists on seat 0\'s own turn at 10 s left'),
      );
      expect(
        _digitsWeight(tester),
        FontWeight.w800,
        reason: s.why('digits are w800 on seat 0\'s own turn at 10 s left'),
      );
      final dynamic ring = tester.widget(find.byKey(_ringKey));
      expect(
        ring.color as Color,
        LudoColors.error,
        reason: s.why('the colour switch to LudoColors.error stays (D6)'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // (m): the beat.
  // ===========================================================================
  testWidgets('C-586 D6 (m): the wrapper beats 1.0 to 1.15 and back inside '
      '300 ms at each shown second; the ring does not change size', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 12000,
      segmentMs: 45000,
    );
    final _Scn s = _Scn('45s segment, seat 1 on turn, beat, 12 s left', tester);
    try {
      final double baseScale = _scaleOf(_countdownRender(tester));
      final Size ringBefore = _ringSize(tester);
      await s.pumpOnce(1000);
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 10, reason: s.why('fixture: 10 shown'));
      expect(find.byKey(_warningKey), findsOneWidget);
      final Size wrapperSize = tester.getSize(find.byKey(_warningKey));
      for (final int second in const <int>[10, 9]) {
        expect(
          _shownSeconds(tester),
          second,
          reason: s.why('fixture: $second shown at the start of this beat'),
        );
        final List<double> ratios = <double>[];
        final List<int> at = <int>[];
        // Frames of the current second, up to 16 ms short of the next tick.
        await s.pumpFrames(
          992,
          onFrame: (int elapsed) {
            ratios.add(_scaleOf(_countdownRender(tester)) / baseScale);
            at.add(elapsed);
            expect(
              _ringSize(tester),
              ringBefore,
              reason: s.why(
                'the ring\'s layout size is unchanged at ${elapsed}ms of '
                'second $second (the beat is a paint transform)',
              ),
            );
            expect(
              tester.getSize(find.byKey(_warningKey)),
              wrapperSize,
              reason: s.why(
                'the wrapper\'s layout size is unchanged at ${elapsed}ms of '
                'second $second',
              ),
            );
          },
        );
        double peak = 1.0;
        for (int i = 0; i < ratios.length; i++) {
          if (at[i] <= 320) {
            peak = math.max(peak, ratios[i]);
          }
        }
        expect(
          peak,
          greaterThan(1.05),
          reason: s.why(
            'some frame within 320 ms of the change to $second s has a '
            'scale above 1.0 (peak ratio $peak; ratios $ratios)',
          ),
        );
        expect(
          peak,
          lessThanOrEqualTo(1.16),
          reason: s.why('the beat peaks at 1.15, not more (peak $peak)'),
        );
        for (int i = 0; i < ratios.length; i++) {
          if (at[i] >= 350) {
            expect(
              ratios[i],
              closeTo(1.0, 0.01),
              reason: s.why(
                'the beat is over by 350 ms: scale ${ratios[i]} at '
                '${at[i]}ms of second $second',
              ),
            );
          }
        }
        await s.pumpOnce(8);
      }
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // (n): reduced motion.
  // ===========================================================================
  testWidgets('C-586 D7 (n): disableAnimations: the wrapper exists, the digits '
      'are w800, the scale is exactly 1.0 at every frame across second '
      'changes', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 12000,
      segmentMs: 45000,
      disableAnimations: true,
    );
    final _Scn s = _Scn('45s segment, reduced motion, 12 s left', tester);
    try {
      final double baseScale = _scaleOf(_countdownRender(tester));
      final Size ringBefore = _ringSize(tester);
      await s.pumpFrames(2000);
      expect(_shownSeconds(tester), 10, reason: s.why('fixture: 10 shown'));
      expect(
        find.byKey(_warningKey),
        findsOneWidget,
        reason: s.why('the wrapper exists under reduced motion at 10 s'),
      );
      expect(
        _digitsWeight(tester),
        FontWeight.w800,
        reason: s.why('digits are w800 under reduced motion'),
      );
      final Size wrapperSize = tester.getSize(find.byKey(_warningKey));
      final List<double> ratios = <double>[];
      await s.pumpFrames(
        2200,
        onFrame: (int elapsed) {
          ratios.add(_scaleOf(_countdownRender(tester)) / baseScale);
          expect(
            _ringSize(tester),
            ringBefore,
            reason: s.why('ring size unchanged at ${elapsed}ms'),
          );
          expect(
            tester.getSize(find.byKey(_warningKey)),
            wrapperSize,
            reason: s.why('wrapper size unchanged at ${elapsed}ms'),
          );
        },
      );
      expect(
        _shownSeconds(tester),
        8,
        reason: s.why('fixture: two more second changes happened'),
      );
      expect(
        ratios.every((double r) => (r - 1.0).abs() < 1e-9),
        isTrue,
        reason: s.why(
          'scale is exactly 1.0 at every frame; max deviation '
          '${ratios.map((double r) => (r - 1.0).abs()).reduce(math.max)}',
        ),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // D6: the end of the window and the time-up hourglass.
  // ===========================================================================
  testWidgets('C-586 D6: at zero the hourglass keeps its look and nothing '
      'beats', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 4000,
      segmentMs: 10000,
    );
    final _Scn s = _Scn('10s segment, 4 s left, run to zero', tester);
    try {
      final double baseScale = _scaleOf(_countdownRender(tester));
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 3, reason: s.why('fixture: 3 shown'));
      expect(find.byKey(_warningKey), findsOneWidget);
      await s.pumpOnce(1000);
      await s.pumpOnce(1000);
      expect(_shownSeconds(tester), 1, reason: s.why('fixture: 1 shown'));
      await s.pumpFrames(992);
      await s.pumpOnce(8);
      expect(
        find.byKey(_timeUpKey),
        findsOneWidget,
        reason: s.why('fixture: the time-up hourglass is shown at zero'),
      );
      expect(
        find.byKey(_digitsKey),
        findsNothing,
        reason: s.why('the digits are gone at zero'),
      );
      final List<double> ratios = <double>[];
      await s.pumpFrames(
        600,
        onFrame: (int elapsed) {
          ratios.add(_scaleOf(_countdownRender(tester)) / baseScale);
        },
      );
      expect(
        ratios.every((double r) => (r - 1.0).abs() < 1e-6),
        isTrue,
        reason: s.why(
          'nothing beats at zero; ratios $ratios (the wrapper may remain '
          'but must not scale)',
        ),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('C-586 D6: the key does not exist outside the window, also '
      'after the screen has been in it (a new segment)', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      mySeat: 0,
      turnSeat: 1,
      deadlineMs: 10000,
      segmentMs: 45000,
    );
    final _Scn s = _Scn(
      '45s segment, 10 s left, then a new turn frame',
      tester,
    );
    try {
      expect(
        find.byKey(_warningKey),
        findsOneWidget,
        reason: s.why('the wrapper exists at 10 s left'),
      );
      s.steps.add('turn seat 0 deadline 45000 segment 45000');
      await drive.push(
        tester,
        'turn',
        _turn(seat: 0, deadlineMs: 45000, segmentMs: 45000)..remove('k'),
      );
      await s.pumpOnce(16);
      expect(_shownSeconds(tester), 45, reason: s.why('fixture: 45 shown'));
      expect(
        _warning(tester),
        isFalse,
        reason: s.why('the wrapper is gone once a fresh segment opens'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  // ===========================================================================
  // D6 (a): the stroke is twice as wide in the window.
  // ===========================================================================
  for (final bool reduced in const <bool>[true, false]) {
    testWidgets(
      'C-586 D6 (a)${reduced ? ' (reduced motion)' : ''}: the ring\'s stroke '
      'is twice its normal width in the window',
      (tester) async {
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: 0,
          turnSeat: 1,
          deadlineMs: 12000,
          segmentMs: 45000,
          disableAnimations: reduced,
        );
        final _Scn s = _Scn(
          '45s segment, stroke thickness, reduced=$reduced',
          tester,
        );
        try {
          await s.pumpOnce(1000);
          expect(_shownSeconds(tester), 11, reason: s.why('fixture: 11'));
          final double normal = await _strokeThickness(s);
          await s.pumpOnce(1000);
          expect(_shownSeconds(tester), 10, reason: s.why('fixture: 10'));
          // Let a beat run out before the pixels are read.
          await s.pumpFrames(500);
          final double warned = await _strokeThickness(s);
          expect(
            warned / normal,
            inInclusiveRange(1.7, 2.3),
            reason: s.why(
              'stroke thickness in the window / outside it is about 2; '
              'measured outside $normal px, inside $warned px',
            ),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }
}
