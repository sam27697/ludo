// Screen proof for work/ludo/orders/610-countdown-digits-inside-ring.md, D1:
// the turn countdown's digits stay inside their ring at every text size, with
// the full value still spoken. Written from the contract alone, against a real
// GameScreen over a real RoomController on FakeTransport
// (test/support/roll_tray_harness.dart), the way test/countdown_warning_test.dart
// drives it. Time moves only by tester.pump(duration); a live countdown never
// meets pumpAndSettle.
//
// The fit rule (a). The digits' laid-out box is the render box of the Text keyed
// game-screen-turn-countdown. Its four corners are carried to GLOBAL coordinates
// through the full transform chain (RenderObject.getTransformTo(null)), so a
// scaling transform between the Text and the ring (a FittedBox, a Transform)
// counts. The centre of those corners must lie within 0.5 dp of the centre of
// the ring's own render box, and half the diagonal between opposite corners
// must be at most 22 - strokeWidth - 1, where 22 is half the 44 dp ring and
// strokeWidth is the stroke in force. The limit is compared with 0.01 dp of
// slack for floating point in a scale-down transform; that is the only
// tolerance on the radius.
//
// The stroke widths. They are private to _CountdownRingPainter: 3.5 at rest
// (restStrokeWidth) and 7.0 in the warning (warningStrokeWidth, twice the rest
// width). The cases state those two numbers as the contract's and ALSO read the
// stroke the ring is painted with from the _CountdownRing widget keyed
// game-header-countdown-ring (its strokeWidth field, which it hands to the
// painter), and fail first if the two disagree, so the limit is never computed
// from a stroke the screen does not draw.
//
// Settling. The warning wraps ring and digits in a beat that scales 1.0 to 1.15
// and back over 300 ms each second. The cases pump 500 ms after the mount,
// inside the same shown second, so the beat has returned to rest before
// anything is measured.
//
// Fonts. flutter test does not load the pubspec faces by itself: without them
// every glyph is the 1 em wide test face, a two-digit string is 2 em wide at
// rest, and no shape could satisfy (a) and (b) at scale 1.0 together. The
// screen ships Poppins (and Noto Sans Arabic as its fallback), so setUpAll loads
// those same asset files under their pubspec family names, the way
// test/arabic_shaping_gap_test.dart does, and the digits are measured in the
// face a player sees.
//
// Every failure reason names the scenario (locale, text scale, state, the
// string shown) and ends with the pumps that led to it. The cases are
// deterministic, so the scenario is the whole reproduction; there is no seed.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, TextBox;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/roll_tray_harness.dart';

const Key _ringKey = Key('game-header-countdown-ring');
const Key _digitsKey = Key('game-screen-turn-countdown');
const Key _semanticsKey = Key('game-header-countdown-semantics');
const Key _warningKey = Key('game-header-countdown-warning');

/// The ring's side, `_countdownRingSize` in game_screen.dart.
const double _ringSide = 44;

/// `_CountdownRingPainter.restStrokeWidth`.
const double _restStroke = 3.5;

/// `_CountdownRingPainter.warningStrokeWidth`, twice the rest width.
const double _warningStroke = 7.0;

const List<double> _scales = <double>[1.0, 1.3, 1.7, 2.0, 3.0];
const List<String> _locales = <String>['en', 'ar'];

class _State {
  const _State(this.name, this.seconds, this.warning);

  final String name;

  /// The whole seconds the countdown shows once mounted.
  final int seconds;
  final bool warning;

  double get stroke => warning ? _warningStroke : _restStroke;
}

// A 45 s turn: 45 shown at rest, the warning window opens at 10 left.
const _State _rest45 = _State('rest-45', 45, false);
const _State _warn10 = _State('warning-10', 10, true);
const _State _warn9 = _State('warning-9', 9, true);
const List<_State> _states = <_State>[_rest45, _warn10, _warn9];

const int _segmentMs = 45000;

class _Scn {
  _Scn(this.locale, this.scale, this.state, this.tester);

  final String locale;
  final double scale;
  final _State state;
  final WidgetTester tester;
  final List<String> steps = <String>[];

  String get name =>
      'C-610 locale=$locale scale=$scale state=${state.name} '
      '(${_segmentMs ~/ 1000} s segment, ${state.seconds} s left)';

  String why(String expected) =>
      '$name | expected: $expected | replay: ${steps.join(' > ')}';

  Future<void> pumpOnce(int ms) async {
    steps.add('pump ${ms}ms');
    await tester.pump(Duration(milliseconds: ms));
  }
}

Map<String, Object?> _turn({required int deadlineMs}) => <String, Object?>{
  'seat': 1,
  'phase': 'await_roll',
  'deadline_ms': deadlineMs,
  'k': 0,
  'segment_ms': _segmentMs,
  'queue': const <int>[],
};

Future<RollTrayDrive> _mount(_Scn s) async {
  final WidgetTester tester = s.tester;
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  s.steps.add(
    'connectPlaying(mySeat 0, seat 1 on turn, deadline_ms '
    '${s.state.seconds * 1000}, segment_ms $_segmentMs)',
  );
  final RollTrayDrive drive = await connectPlaying(
    tester,
    mySeat: 0,
    turn: _turn(deadlineMs: s.state.seconds * 1000),
  );
  s.steps.add('mount 360x800 dpr 1 textScale ${s.scale} locale ${s.locale}');
  await mountGame(tester, drive, locale: Locale(s.locale), textScale: s.scale);
  expect(
    find.byKey(_ringKey),
    findsOneWidget,
    reason: s.why('fixture: game-header-countdown-ring is on screen'),
  );
  await s.pumpOnce(500);
  return drive;
}

// --- reading the screen ------------------------------------------------------

/// The whole seconds shown by the Text keyed game-screen-turn-countdown.
int? _shownSeconds(WidgetTester tester) {
  final Finder f = find.byKey(_digitsKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final String? data = _digitsText(tester).data;
  final Match? m = RegExp(r'\d+').firstMatch(data ?? '');
  return m == null ? null : int.parse(m.group(0)!);
}

Text _digitsText(WidgetTester tester) {
  final Finder f = find.byKey(_digitsKey);
  final Widget w = tester.widget(f);
  return w is Text
      ? w
      : tester.widget<Text>(
          find.descendant(of: f, matching: find.byType(Text)).first,
        );
}

/// A render box's four corners carried to global coordinates.
class _GlobalBox {
  _GlobalBox._(this.corners);

  factory _GlobalBox.of(RenderObject render) {
    final RenderBox box = render as RenderBox;
    final Matrix4 m = box.getTransformTo(null);
    final Size size = box.size;
    return _GlobalBox._(<Offset>[
      MatrixUtils.transformPoint(m, Offset.zero),
      MatrixUtils.transformPoint(m, Offset(size.width, 0)),
      MatrixUtils.transformPoint(m, Offset(size.width, size.height)),
      MatrixUtils.transformPoint(m, Offset(0, size.height)),
    ]);
  }

  /// The render box with its width replaced by the width the paragraph laid its
  /// glyphs out in (the union of its line boxes). The height stays the render
  /// height: the line boxes of a `height: 1` style report the font's own taller
  /// metrics, which is not what the contract measures. Unlike the render size,
  /// the width is not clamped by the constraints the parent passes down.
  factory _GlobalBox.ofGlyphs(RenderParagraph paragraph) {
    final List<TextBox> boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    );
    Rect union = boxes.first.toRect();
    for (final TextBox b in boxes.skip(1)) {
      union = union.expandToInclude(b.toRect());
    }
    final Rect laid = Rect.fromLTWH(
      union.left,
      0,
      union.width,
      paragraph.size.height,
    );
    final Matrix4 m = paragraph.getTransformTo(null);
    return _GlobalBox._(<Offset>[
      MatrixUtils.transformPoint(m, laid.topLeft),
      MatrixUtils.transformPoint(m, laid.topRight),
      MatrixUtils.transformPoint(m, laid.bottomRight),
      MatrixUtils.transformPoint(m, laid.bottomLeft),
    ]);
  }

  /// Top-left, top-right, bottom-right, bottom-left.
  final List<Offset> corners;

  Offset get centre => (corners[0] + corners[1] + corners[2] + corners[3]) / 4;

  /// The longer of the two diagonals, halved.
  double get halfDiagonal =>
      math.max(
        (corners[2] - corners[0]).distance,
        (corners[3] - corners[1]).distance,
      ) /
      2;

  double get height {
    final Iterable<double> ys = corners.map((Offset c) => c.dy);
    return ys.reduce(math.max) - ys.reduce(math.min);
  }

  double get width {
    final Iterable<double> xs = corners.map((Offset c) => c.dx);
    return xs.reduce(math.max) - xs.reduce(math.min);
  }
}

/// The stroke the ring is painted with (the field the widget hands to
/// _CountdownRingPainter).
double _paintedStroke(WidgetTester tester) {
  final dynamic ring = tester.widget(find.byKey(_ringKey));
  return (ring.strokeWidth as num).toDouble();
}

/// Mounts one scenario and checks the fixture: the number shown, the warning
/// wrapper, the ring's size and stroke.
Future<RollTrayDrive> _mountChecked(_Scn s) async {
  final RollTrayDrive drive = await _mount(s);
  final WidgetTester tester = s.tester;
  expect(
    _shownSeconds(tester),
    s.state.seconds,
    reason: s.why('fixture: ${s.state.seconds} shown by the digits'),
  );
  expect(
    tester.any(find.byKey(_warningKey)),
    s.state.warning,
    reason: s.why(
      s.state.warning
          ? 'fixture: the warning wrapper exists'
          : 'fixture: no warning wrapper',
    ),
  );
  final _GlobalBox ring = _GlobalBox.of(
    tester.renderObject(find.byKey(_ringKey)),
  );
  expect(
    ring.width,
    closeTo(_ringSide, 0.01),
    reason: s.why('the ring stays $_ringSide dp wide, got ${ring.width}'),
  );
  expect(
    ring.height,
    closeTo(_ringSide, 0.01),
    reason: s.why('the ring stays $_ringSide dp tall, got ${ring.height}'),
  );
  expect(
    _paintedStroke(tester),
    s.state.stroke,
    reason: s.why(
      'the ring is painted with the contract stroke ${s.state.stroke} '
      '(_CountdownRingPainter)',
    ),
  );
  return drive;
}

Future<void> _loadFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

String _fmt(double v) => v.toStringAsFixed(3);

void main() {
  setUpAll(_loadFonts);

  // ===========================================================================
  // (a): the digits' box lies inside the ring's inner edge, 1 dp to spare.
  // ===========================================================================
  for (final String locale in _locales) {
    for (final double scale in _scales) {
      for (final _State state in _states) {
        testWidgets(
          'C-610 D1 (a): $locale, text scale $scale, ${state.name}: digits '
          'centred in the ring and inside its inner edge',
          (tester) async {
            final _Scn s = _Scn(locale, scale, state, tester);
            final RollTrayDrive drive = await _mountChecked(s);
            try {
              final _GlobalBox ring = _GlobalBox.of(
                tester.renderObject(find.byKey(_ringKey)),
              );
              final _GlobalBox digits = _GlobalBox.of(
                tester.renderObject(find.byKey(_digitsKey)),
              );
              final double limit = 22 - state.stroke - 1;
              final double offCentre = (digits.centre - ring.centre).distance;
              final _GlobalBox glyphs = _GlobalBox.ofGlyphs(
                tester.renderObject<RenderParagraph>(find.byKey(_digitsKey)),
              );
              final List<String> problems = <String>[];
              if (offCentre > 0.5) {
                problems.add(
                  'digits box centre must be within 0.5 dp of the ring '
                  'centre; digits centre ${digits.centre}, ring centre '
                  '${ring.centre}, off by ${_fmt(offCentre)} dp',
                );
              }
              if (digits.halfDiagonal > limit + 0.01) {
                problems.add(
                  'half the digits render box diagonal must be <= 22 - '
                  '${state.stroke} - 1 = $limit dp; the box is '
                  '${_fmt(digits.width)} x ${_fmt(digits.height)} dp '
                  'globally, half diagonal ${_fmt(digits.halfDiagonal)} dp, '
                  'over by ${_fmt(digits.halfDiagonal - limit)} dp',
                );
              }
              if (glyphs.halfDiagonal > limit + 0.01) {
                problems.add(
                  'half the diagonal of the box of the laid-out glyph width by the '
                  'render height (the render width can be clamped by the '
                  'parent and under-report) must be <= $limit dp; it is '
                  '${_fmt(glyphs.width)} x ${_fmt(glyphs.height)} dp '
                  'globally, half diagonal ${_fmt(glyphs.halfDiagonal)} dp, '
                  'over by ${_fmt(glyphs.halfDiagonal - limit)} dp',
                );
              }
              if (problems.isNotEmpty) {
                fail(s.why(problems.join(' ; AND ; ')));
              }
            } finally {
              await releaseGame(tester, drive);
            }
          },
        );
      }
    }
  }

  // ===========================================================================
  // (b): where the digits already fit they are exactly today's size.
  // ===========================================================================
  for (final String locale in _locales) {
    testWidgets(
      'C-610 D1 (b): $locale, text scale 1.0, rest: the digits are painted at '
      'the unshrunk kTypeLabel w600 height 1 size',
      (tester) async {
        final _Scn s = _Scn(locale, 1.0, _rest45, tester);
        final RollTrayDrive drive = await _mountChecked(s);
        try {
          final Text text = _digitsText(tester);
          final String shown = text.data ?? text.textSpan!.toPlainText();
          final TextPainter painter = TextPainter(
            text: TextSpan(
              text: shown,
              style: const TextStyle(
                fontSize: kTypeLabel,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
            textDirection: locale == 'ar'
                ? TextDirection.rtl
                : TextDirection.ltr,
            textScaler: TextScaler.noScaling,
          )..layout();
          final double expected = painter.height;
          painter.dispose();
          final _GlobalBox digits = _GlobalBox.of(
            tester.renderObject(find.byKey(_digitsKey)),
          );
          expect(
            digits.height,
            closeTo(expected, 0.5),
            reason: s.why(
              'painted global height of "$shown" equals a TextPainter at '
              'kTypeLabel $kTypeLabel w600 height 1 scale 1.0 '
              '(${_fmt(expected)} dp, +-0.5); got ${_fmt(digits.height)} dp '
              '(a shrink where it already fits)',
            ),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  // ===========================================================================
  // (c): the spoken label carries the full value at the largest text size.
  // ===========================================================================
  for (final String locale in _locales) {
    for (final _State state in _states) {
      testWidgets(
        'C-610 D1 (c): $locale, text scale 3.0, ${state.name}: the semantics '
        'label is gameTurnCountdown(${state.seconds})',
        (tester) async {
          final _Scn s = _Scn(locale, 3.0, state, tester);
          final RollTrayDrive drive = await _mountChecked(s);
          try {
            final AppLocalizations loc = AppLocalizations.of(
              tester.element(find.byKey(_semanticsKey)),
            );
            final String expected = loc.gameTurnCountdown(state.seconds);
            final Semantics semantics = tester.widget<Semantics>(
              find.byKey(_semanticsKey),
            );
            expect(
              semantics.properties.label,
              expected,
              reason: s.why(
                'game-header-countdown-semantics label is '
                'gameTurnCountdown(${state.seconds}) = "$expected"; got '
                '"${semantics.properties.label}"',
              ),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  }
}
