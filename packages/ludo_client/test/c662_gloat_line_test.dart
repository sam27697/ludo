// Screen proof for C-662 T1-T6 (order 662t): the gloat says something.
// Written from the contract's text alone. A real GameScreen over a real
// RoomController on FakeTransport, every state a decoded wire frame, the
// recording FeedbackService from support/roll_tray_harness.dart.
//
// This file does not compile on a tree without AppLocalizations.gloatLine1
// to gloatLine8, which is the expected failing arm on the base.
//
// Where the line is. The contract does not name the widget, so the line is
// found by what it says: the one RichText (what a Text draws) on screen
// whose plain text is one of the eight pool strings, en or ar. That holds
// whether the line sits under `capture-gloat-<seat>` or beside it on the
// board, and a pool string appears nowhere else on the game screen. Its
// geometry is read through the full transform to the screen, so a FittedBox
// that shrinks a long line to fit still measures what is painted. The pill
// is the nearest DecoratedBox above the text; the contract's "rounded pill
// in the capturer's seat colour" is read as a BoxDecoration with a
// borderRadius of at least half the pill's height and the seat colour as
// its fill. The face's own rect is the one the C-468 proof measures
// (`capture-gloat-<seat>`, two cells).
//
// Order. The pool is a shuffled bag, so which line shows is not known from
// outside. The cases that need the bag fresh (eight different lines in a
// row, the ninth differing from the eighth) come first in this file and
// make no other gloat before them. Every later case that draws a line holds
// for any bag position. No seed is taken from the clock; the scenarios hold
// no randomness, so the scenario name is the whole seed.
//
// Time is measured from the first frame the gloat is on screen, in 5 ms
// pumps unless a case says otherwise. Every failure reason starts with the
// scenario name and ends with the frames and pumps that led to it.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const List<int> _moverTokens = <int>[3, -1, -1, -1];
const List<int> _victimTokens = <int>[-1, -1, 48, -1];

/// C-468 D5 and C-579 D2: the face's whole life and its exit, in ms.
const int _lifeMs = 1600;
const int _exitMs = 250;

/// T1: the pool exactly as the contract's table gives it, en then ar.
const List<(String, String)> _table = <(String, String)>[
  ('Back to the yard!', 'رجعتك عالبيت!'),
  ('From the top!', 'يلا، من الأول!'),
  ('Not this time!', 'مش هالمرة!'),
  ('Where are you off to?', 'وين رايح؟'),
  ('Say hi to the yard!', 'سلّملي عالبيت!'),
  ('This road is mine!', 'هالطريق إلي!'),
  ('Too slow!', 'بطيء كتير!'),
  ('See you at the start!', 'منشوفك بالبداية!'),
];

const String _lineDescription =
    'Short playful line shown over the laughing face after a capture.';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

List<String> _poolOf(Locale locale) {
  final AppLocalizations l = lookupAppLocalizations(locale);
  return <String>[
    l.gloatLine1,
    l.gloatLine2,
    l.gloatLine3,
    l.gloatLine4,
    l.gloatLine5,
    l.gloatLine6,
    l.gloatLine7,
    l.gloatLine8,
  ];
}

Set<String> _everyLine() => <String>{..._poolOf(_en), ..._poolOf(_ar)};

/// The line, wherever it sits: a RichText whose plain text is a pool string.
Finder _lineFinder() => find.byWidgetPredicate(
  (Widget w) => w is RichText && _everyLine().contains(w.text.toPlainText()),
  description: 'a gloat pool line',
);

Future<void> _loadAppFonts() async {
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
  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

/// One capture scenario: me, the mover M and the captured seat.
class _Fix {
  _Fix(
    this.s,
    this.me,
    this.mover,
    this.victim,
    this.locale,
    this.players,
    this.reduced,
    this.seats,
  );

  final Scn s;
  final int me;
  final int mover;
  final int victim;
  final Locale locale;
  final int players;
  final bool reduced;
  final List<Map<String, Object?>> seats;

  /// True once a capture frame has been pushed; [_awaitFace] pushes the
  /// plain capture when none has.
  bool pushed = false;

  WidgetTester get tester => s.tester;

  Finder get face => find.byKey(gloatKey(mover));

  List<String> get pool => _poolOf(locale);
}

Future<_Fix> _fixture(
  WidgetTester tester, {
  required String name,
  required int mover,
  int me = 0,
  int players = 2,
  Locale locale = _en,
  bool reduced = false,
  double textScale = 1.0,
  Size surface = const Size(360, 800),
  List<int> victimTokens = _victimTokens,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final int victim = players == 2
      ? (mover == me ? (me == 0 ? 2 : 0) : me)
      : (mover + 2) % 4;
  final List<Map<String, Object?>> seats = players == 2
      ? <Map<String, Object?>>[
          for (final int seat in const <int>[0, 2])
            seatJson(
              seat,
              name: seat == me ? 'Sam' : 'Bob',
              tokens: seat == mover ? _moverTokens : victimTokens,
            ),
        ]
      : quadSeats(
          mySeat: me,
          tokens: <int, List<int>>{mover: _moverTokens, victim: victimTokens},
        );
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: awaitRollTurn(mover),
    seats: seats,
    mySeat: me,
    players: players,
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    textScale: textScale,
    disableAnimations: reduced,
  );
  return _Fix(
    Scn(name, tester, drive),
    me,
    mover,
    victim,
    locale,
    players,
    reduced,
    seats,
  );
}

Future<void> _pushCapture(
  _Fix f, {
  bool extraRoll = false,
  List<int>? victims,
}) {
  f.pushed = true;
  return f.s.push(
    'moved',
    movedFrame(
      f.mover,
      0,
      3,
      9,
      captured: <Map<String, int>>[
        for (final int seat in victims ?? <int>[f.victim])
          <String, int>{'seat': seat, 'token': 2},
      ],
      extraRoll: extraRoll,
    ),
  );
}

/// The scenario's reason text: its name, what was expected, the clock and
/// the frames and pumps that led there, runs of equal pumps folded.
String _why(Scn s, String expected) {
  final List<String> folded = <String>[];
  int run = 0;
  for (int i = 0; i < s.steps.length; i++) {
    run += 1;
    if (i + 1 == s.steps.length || s.steps[i + 1] != s.steps[i]) {
      folded.add(run > 1 ? '${s.steps[i]} x$run' : s.steps[i]);
      run = 0;
    }
  }
  return '${s.name} | expected: $expected | at ${s.clockMs}ms | replay: '
      '${folded.join(' > ')}';
}

/// One pump on the fake clock, kept out of the replay list.
Future<void> _tick(Scn s, [Duration step = kC468Fine]) async {
  await s.tester.pump(step);
  s.clockMs += step.inMilliseconds;
}

Future<void> _pumpTo(Scn s, int clockMs) async {
  s.steps.add('pump to ${clockMs}ms');
  while (s.clockMs < clockMs) {
    await _tick(s);
  }
}

/// The text of the one line on screen; null when there is none. More than
/// one is a failure of its own.
String? _lineNow(_Fix f) {
  final List<Element> found = _lineFinder().evaluate().toList();
  if (found.length > 1) {
    fail(
      _why(
        f.s,
        'at most one gloat line on screen, found ${found.length}: '
        '${<String>[for (final Element e in found) (e.widget as RichText).text.toPlainText()]}',
      ),
    );
  }
  return found.isEmpty
      ? null
      : (found.single.widget as RichText).text.toPlainText();
}

/// Pumps until the face is on screen; returns the clock reading of the
/// first frame it showed on, with the line already on that frame.
Future<int> _awaitFace(_Fix f, {Duration step = kC468Fine}) async {
  if (!f.pushed) {
    await _pushCapture(f);
  }
  final int? t0 = await pumpUntilGloat(f.s, step: step);
  expect(
    t0,
    isNotNull,
    reason: _why(f.s, 'a capturing moved starts a gloat for seat ${f.mover}'),
  );
  expect(
    _lineNow(f),
    isNotNull,
    reason: _why(
      f.s,
      'the line shows on the very frame the face first shows on (no pool '
      'line text in the tree)',
    ),
  );
  return t0!;
}

Rect _screenRect(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

double _opacityAbove(RenderObject start) {
  double product = 1.0;
  RenderObject? at = start;
  while (at != null) {
    if (at is RenderOpacity) {
      product *= at.opacity;
    } else if (at is RenderAnimatedOpacity) {
      product *= at.opacity.value;
    }
    at = at.parent;
  }
  return product;
}

class _Pill {
  _Pill(this.box, this.decoration);

  final RenderBox box;
  final BoxDecoration decoration;

  Rect get rect => _screenRect(box);
}

/// The nearest DecoratedBox with a BoxDecoration above the line's text.
_Pill? _pillOf(WidgetTester tester, Finder line) {
  _Pill? found;
  tester.element(line).visitAncestorElements((Element ancestor) {
    final Widget w = ancestor.widget;
    if (w is DecoratedBox && w.decoration is BoxDecoration) {
      found = _Pill(
        ancestor.renderObject! as RenderBox,
        w.decoration as BoxDecoration,
      );
      return false;
    }
    return true;
  });
  return found;
}

/// How many lines the paragraph lays out at the width it was given, read
/// back with a painter set up the same way.
int _lineCount(WidgetTester tester, Finder line) {
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(line);
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textAlign: paragraph.textAlign,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    maxLines: paragraph.maxLines,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  final int count = painter.computeLineMetrics().length;
  painter.dispose();
  return count;
}

bool _sameRgb(Color a, Color b) =>
    (a.r - b.r).abs() < 0.008 &&
    (a.g - b.g).abs() < 0.008 &&
    (a.b - b.b).abs() < 0.008;

bool _inside(Rect outer, Rect inner) =>
    outer.inflate(0.5).contains(inner.topLeft) &&
    outer.inflate(0.5).contains(inner.bottomRight);

/// One look at the face and the line, `age` ms from the sampling origin.
class _Look {
  _Look({
    required this.age,
    required this.face,
    required this.line,
    this.text,
    this.faceOpacity = 0,
    this.lineOpacity = 0,
    this.faceScale = 0,
    this.faceCentre = Offset.zero,
    this.lineCentre = Offset.zero,
    this.lineScale = 0,
    this.lineDegrees = 0,
    this.textRect = Rect.zero,
    this.pillRect,
    this.lines = 0,
  });

  final int age;
  final bool face;
  final bool line;
  final String? text;
  final double faceOpacity;
  final double lineOpacity;
  final double faceScale;
  final Offset faceCentre;
  final Offset lineCentre;
  final double lineScale;
  final double lineDegrees;
  final Rect textRect;
  final Rect? pillRect;
  final int lines;

  @override
  String toString() =>
      '$age:${face ? 'F${faceOpacity.toStringAsFixed(2)}' : '-'}'
      '${line ? 'L${lineOpacity.toStringAsFixed(2)}@'
                '${lineCentre.dx.toStringAsFixed(1)},'
                '${lineCentre.dy.toStringAsFixed(1)}' : '-'}';
}

_Look _look(_Fix f, int origin) {
  final WidgetTester t = f.tester;
  final int age = f.s.clockMs - origin;
  final bool face = t.any(f.face);
  final Finder lineFinder = _lineFinder();
  final String? text = _lineNow(f);
  double faceOpacity = 0;
  double faceScale = 0;
  Offset faceCentre = Offset.zero;
  if (face) {
    faceOpacity = _opacityAbove(paintObjectOf(t, f.face));
    faceScale = poseOf(t, f.face).scale;
    faceCentre = paintCentreOf(t, f.face);
  }
  if (text == null) {
    return _Look(
      age: age,
      face: face,
      line: false,
      faceOpacity: faceOpacity,
      faceScale: faceScale,
      faceCentre: faceCentre,
    );
  }
  final RenderBox para = t.renderObject<RenderBox>(lineFinder);
  final Matrix4 m = para.getTransformTo(null);
  final double a = m.storage[0];
  final double b = m.storage[1];
  final Rect textRect = _screenRect(para);
  return _Look(
    age: age,
    face: face,
    line: true,
    text: text,
    faceOpacity: faceOpacity,
    lineOpacity: _opacityAbove(para),
    faceScale: faceScale,
    faceCentre: faceCentre,
    lineCentre: textRect.center,
    lineScale: math.sqrt(a * a + b * b),
    lineDegrees: math.atan2(b, a) * 180 / math.pi,
    textRect: textRect,
    pillRect: _pillOf(t, lineFinder)?.rect,
    lines: _lineCount(t, lineFinder),
  );
}

String _series(List<_Look> looks) {
  final List<String> out = <String>[];
  int next = 0;
  for (final _Look l in looks) {
    if (l.age >= next || !(l.face || l.line)) {
      out.add('$l');
      next = l.age + 100;
    }
  }
  return out.join(' ');
}

/// Looks every [step] from now until neither the face nor the line is on
/// screen, or the clock reads [until]; the last entry is the first look
/// with both gone, if any.
Future<List<_Look>> _watch(
  _Fix f, {
  required int origin,
  required int until,
  Duration step = kC468Fine,
}) async {
  f.s.steps.add('watch every ${step.inMilliseconds}ms from ${f.s.clockMs}ms');
  final List<_Look> looks = <_Look>[];
  while (f.s.clockMs <= until) {
    looks.add(_look(f, origin));
    if (!looks.last.face && !looks.last.line) {
      break;
    }
    await _tick(f.s, step);
  }
  f.s.steps.add('watched to ${f.s.clockMs}ms');
  return looks;
}

/// T2: the line and the face come and go on the same frame, share one
/// opacity, and keep one offset from each other; the line itself never
/// takes the pop's scale or the wobble's turn. [reference] is the look the
/// offset and the line's own pose are measured against.
void _expectTogether(_Fix f, List<_Look> looks, {String? what}) {
  final String tag = what == null ? '' : '$what: ';
  final String series = _series(looks);
  final _Look ref = looks.first;
  for (final _Look l in looks) {
    expect(
      l.line,
      l.face,
      reason: _why(
        f.s,
        '$tag${l.age}ms: the line is on screen exactly when the face is '
        '(face ${l.face}, line ${l.line}); looks: $series',
      ),
    );
    if (!l.face || !l.line) {
      continue;
    }
    expect(
      l.lineOpacity,
      closeTo(l.faceOpacity, 0.02),
      reason: _why(
        f.s,
        '$tag${l.age}ms: the line follows the face\'s opacity '
        '${l.faceOpacity.toStringAsFixed(3)}, painted at '
        '${l.lineOpacity.toStringAsFixed(3)}; looks: $series',
      ),
    );
    final Offset rel = l.lineCentre - l.faceCentre;
    final Offset relRef = ref.lineCentre - ref.faceCentre;
    expect(
      (rel - relRef).distance,
      lessThan(1.0),
      reason: _why(
        f.s,
        '$tag${l.age}ms: the line keeps its place relative to the face '
        '(rise follows the face): offset $rel against $relRef at '
        '${ref.age}ms; looks: $series',
      ),
    );
    expect(
      l.lineScale,
      closeTo(ref.lineScale, 0.01),
      reason: _why(
        f.s,
        '$tag${l.age}ms: the line does not scale with the pop: scale '
        '${l.lineScale.toStringAsFixed(3)} against '
        '${ref.lineScale.toStringAsFixed(3)} at ${ref.age}ms; looks: $series',
      ),
    );
    expect(
      l.lineDegrees,
      closeTo(ref.lineDegrees, 0.1),
      reason: _why(
        f.s,
        '$tag${l.age}ms: the line does not turn with the wobble: '
        '${l.lineDegrees.toStringAsFixed(2)} degrees against '
        '${ref.lineDegrees.toStringAsFixed(2)} at ${ref.age}ms; looks: '
        '$series',
      ),
    );
  }
}

/// The turn frame that follows a capture's bonus roll, then that roll.
Future<void> _rollFor(_Fix f, int seat) async {
  await f.s.push('turn', turnFrame(seat));
  await f.s.push('rolled', rolledFrame(seat, 6, 1, legal: const <int>[0]));
}

/// The captured seat's token returns to the board for the next capture: a
/// room snapshot (a snapshot never starts a gloat), then the next frame is
/// a capture again.
Future<void> _resetBoard(_Fix f) => f.s.push(
  'room',
  roomData(seats: f.seats, players: f.players, turn: awaitRollTurn(f.mover)),
);

/// Plays [count] gloats one after the other and returns the line each
/// showed.
Future<List<String>> _gloatSequence(_Fix f, int count) async {
  final List<String> lines = <String>[];
  for (int i = 0; i < count; i++) {
    if (i > 0) {
      await f.s.pump(
        const Duration(milliseconds: 1700),
        step: const Duration(milliseconds: 100),
      );
      expect(
        _lineNow(f),
        isNull,
        reason: _why(f.s, 'fixture: gloat #$i is gone before gloat #${i + 1}'),
      );
      await _resetBoard(f);
    }
    f.s.steps.add('gloat #${i + 1}');
    await _pushCapture(f);
    await _awaitFace(f, step: kC468Frame);
    lines.add(_lineNow(f)!);
  }
  return lines;
}

List<String> _semanticsMentioning(WidgetTester tester, Set<String> needles) {
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final List<String> hits = <String>[];
  int nodes = 0;
  void visit(SemanticsNode node) {
    nodes++;
    final SemanticsData data = node.getSemanticsData();
    for (final String text in <String>[
      data.label,
      data.value,
      data.hint,
      data.tooltip,
    ]) {
      if (needles.any(text.contains)) {
        hits.add('node ${node.id}: "$text"');
      }
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  if (nodes < 3) {
    fail('the semantics tree has only $nodes nodes: the probe saw nothing');
  }
  return hits;
}

void main() {
  setUpAll(_loadAppFonts);

  // -------------------------------------------------------------------
  // T3 first: the bag is fresh, no gloat has been drawn before these.
  // -------------------------------------------------------------------
  testWidgets(
    'T3: eight consecutive gloats show eight different lines, all from the '
    'en pool, and the ninth differs from the eighth',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T3 fresh bag en: nine captures by seat 2, I am seat 0',
        mover: 2,
      );
      try {
        final List<String> lines = await _gloatSequence(f, 9);
        final List<String> bad = <String>[];
        final Set<String> pool = f.pool.toSet();
        for (int i = 0; i < lines.length; i++) {
          if (!pool.contains(lines[i])) {
            bad.add(
              'gloat #${i + 1} showed "${lines[i]}", not an en pool line',
            );
          }
        }
        if (lines.take(8).toSet().length != 8) {
          bad.add(
            'the first eight gloats showed ${lines.take(8).toSet().length} '
            'different lines, expected 8 (no repeat until all eight have '
            'shown)',
          );
        }
        if (lines[8] == lines[7]) {
          bad.add(
            'the ninth gloat repeated the eighth ("${lines[8]}"): a refill '
            'never starts with the line that just showed',
          );
        }
        expect(
          bad,
          isEmpty,
          reason: _why(
            f.s,
            'eight different lines then a ninth that differs from the '
            'eighth; sequence: $lines; problems: $bad',
          ),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets(
    'T3: twenty-four gloats in ar from any bag position: every line is an '
    'ar pool line, no line twice running, every sixteen in a row hold all '
    'eight, and one run of eight is a whole bag',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T3 any bag position ar: 24 captures by seat 0, I am seat 0',
        mover: 0,
        locale: _ar,
      );
      try {
        final List<String> lines = await _gloatSequence(f, 24);
        final List<String> bad = <String>[];
        final Set<String> pool = f.pool.toSet();
        for (int i = 0; i < lines.length; i++) {
          if (!pool.contains(lines[i])) {
            bad.add(
              'gloat #${i + 1} showed "${lines[i]}", not an ar pool line',
            );
          }
          if (i > 0 && lines[i] == lines[i - 1]) {
            bad.add('gloats #$i and #${i + 1} both showed "${lines[i]}"');
          }
        }
        for (int s = 0; s + 16 <= lines.length; s++) {
          final int distinct = lines.sublist(s, s + 16).toSet().length;
          if (distinct != 8) {
            bad.add(
              'gloats #${s + 1} to #${s + 16} showed $distinct different '
              'lines, expected all 8',
            );
          }
        }
        bool wholeBag = false;
        for (int s = 0; s <= 8 && !wholeBag; s++) {
          wholeBag = lines.sublist(s, s + 8).toSet().length == 8;
        }
        if (!wholeBag) {
          bad.add(
            'no run of eight in the first sixteen gloats was eight '
            'different lines: the bag is not a shuffled permutation',
          );
        }
        expect(
          bad,
          isEmpty,
          reason: _why(
            f.s,
            'a shuffled bag refilled when empty; sequence: $lines; '
            'problems: $bad',
          ),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // T1: the pool.
  // -------------------------------------------------------------------
  for (final (Locale locale, int column) in const <(Locale, int)>[
    (_en, 0),
    (_ar, 1),
  ]) {
    test('T1: AppLocalizations ${locale.languageCode} holds the eight '
        'lines of the contract, gloatLine1 to gloatLine8 in order', () {
      final List<String> pool = _poolOf(locale);
      final List<String> want = <String>[
        for (final (String, String) row in _table)
          column == 0 ? row.$1 : row.$2,
      ];
      expect(
        pool,
        want,
        reason:
            'T1 ${locale.languageCode}: gloatLine1..8 are exactly the '
            'contract table; got $pool',
      );
      expect(
        pool.toSet().length,
        8,
        reason: 'T1 ${locale.languageCode}: eight different lines',
      );
    });
  }

  test('T1: both arb files carry gloatLine1..8, the en file with the '
      'contract description on each', () {
    final Map<String, Object?> en = jsonDecode(
      File('lib/l10n/app_en.arb').readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, Object?> ar = jsonDecode(
      File('lib/l10n/app_ar.arb').readAsStringSync(),
    ) as Map<String, Object?>;
    for (int i = 0; i < 8; i++) {
      final String key = 'gloatLine${i + 1}';
      expect(
        en[key],
        _table[i].$1,
        reason: 'T1: app_en.arb $key is "${_table[i].$1}"',
      );
      expect(
        ar[key],
        _table[i].$2,
        reason: 'T1: app_ar.arb $key is "${_table[i].$2}"',
      );
      final Object? meta = en['@$key'];
      expect(
        meta is Map<String, Object?> ? meta['description'] : null,
        _lineDescription,
        reason: 'T1: app_en.arb @$key carries the contract description',
      );
    }
  });

  // -------------------------------------------------------------------
  // T2: every phone that draws the face draws the line.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[_en, _ar]) {
    for (final (int me, int mover, int players, String view)
        in const <(int, int, int, String)>[
          (0, 0, 2, 'the capturer is me'),
          (0, 2, 2, 'the capturer is the other player'),
          (1, 0, 4, 'a third seat watches'),
          (2, 0, 4, 'the captured seat watches'),
          (3, 0, 4, 'another third seat watches'),
        ]) {
      testWidgets(
        'T2: ${locale.languageCode}, $view (me $me, seat $mover, $players '
        'players): the line is up with the face, one of the pool for the '
        'locale, gone with it',
        (tester) async {
          final _Fix f = await _fixture(
            tester,
            name:
                'T2 shows ${locale.languageCode} me=$me mover=$mover '
                'players=$players',
            me: me,
            mover: mover,
            players: players,
            locale: locale,
          );
          try {
            await _pushCapture(f);
            expect(
              _lineNow(f),
              isNull,
              reason: _why(f.s, 'no line before the face'),
            );
            final int t0 = await _awaitFace(f);
            final String line = _lineNow(f)!;
            expect(
              f.pool,
              contains(line),
              reason: _why(
                f.s,
                'the line "$line" is one of the ${locale.languageCode} '
                'pool ${f.pool}',
              ),
            );
            final List<_Look> looks = await _watch(
              f,
              origin: t0,
              until: t0 + _lifeMs + 200,
            );
            _expectTogether(f, looks);
            expect(
              looks.last.face || looks.last.line,
              isFalse,
              reason: _why(
                f.s,
                'the face and the line are both gone within the life + '
                '200 ms; looks: ${_series(looks)}',
              ),
            );
            expect(
              looks.where((_Look l) => l.line).map((_Look l) => l.text),
              everyElement(line),
              reason: _why(f.s, 'the line never changes while the face is up'),
            );
          } finally {
            await releaseGame(tester, f.s.drive);
          }
        },
      );
    }
  }

  testWidgets(
    'T2: one move that strikes two seats draws one face and one line',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T2 two victims: seat 0 strikes seats 1 and 2, I am seat 3',
        mover: 0,
        me: 3,
        players: 4,
      );
      try {
        await _pushCapture(f, victims: const <int>[1, 2]);
        final int t0 = await _awaitFace(f);
        final List<_Look> looks = await _watch(
          f,
          origin: t0,
          until: t0 + _lifeMs + 200,
        );
        expect(
          looks.map((_Look l) => l.text).whereType<String>().toSet(),
          hasLength(1),
          reason: _why(f.s, 'one gloat, one line; looks: ${_series(looks)}'),
        );
        _expectTogether(f, looks);
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  for (final Locale locale in const <Locale>[_en, _ar]) {
    for (final int mover in const <int>[0, 1, 2, 3]) {
      testWidgets(
        'T2: ${locale.languageCode}, seat $mover\'s line sits directly above '
        'the face, centred on it, clear of it, one line, at most 2.6 cells '
        'wide, inside the board',
        (tester) async {
          final _Fix f = await _fixture(
            tester,
            name: 'T2 place ${locale.languageCode} me=0 mover=$mover players=4',
            mover: mover,
            players: 4,
            locale: locale,
          );
          try {
            final int t0 = await _awaitFace(f);
            await _pumpTo(f.s, t0 + 1000);
            expect(gloatSeats(tester), <int>[
              mover,
            ], reason: _why(f.s, 'fixture: the face is up in its hold'));
            final Rect face = tester.getRect(f.face);
            final double cell = cellSize(tester);
            final _Look look = _look(f, t0);
            expect(look.line, isTrue, reason: _why(f.s, 'fixture: line is up'));
            final Rect? pill = look.pillRect;
            expect(
              pill,
              isNotNull,
              reason: _why(
                f.s,
                'a DecoratedBox with a BoxDecoration (the pill) sits above '
                'the line text',
              ),
            );
            final Rect box = pill!;
            expect(
              box.center.dx,
              closeTo(face.center.dx, 1.0),
              reason: _why(
                f.s,
                'the pill $box is centred on the face $face (dx '
                '${face.center.dx})',
              ),
            );
            expect(
              box.bottom,
              lessThanOrEqualTo(face.top - 0.5),
              reason: _why(
                f.s,
                'the pill $box lies above the face $face with a gap',
              ),
            );
            expect(
              face.top - box.bottom,
              lessThanOrEqualTo(0.5 * cell),
              reason: _why(
                f.s,
                'the gap ${(face.top - box.bottom).toStringAsFixed(1)} px '
                'between pill and face is small (at most half a cell, '
                '${(cell / 2).toStringAsFixed(1)} px)',
              ),
            );
            expect(
              box.width,
              lessThanOrEqualTo(2.6 * cell + 0.5),
              reason: _why(
                f.s,
                'the pill is ${box.width.toStringAsFixed(1)} px wide, at '
                'most 2.6 cells = ${(2.6 * cell).toStringAsFixed(1)} px at '
                'text scale 1.0',
              ),
            );
            expect(
              look.lines,
              1,
              reason: _why(f.s, '"${look.text}" is drawn on one line'),
            );
            expect(
              _inside(box, look.textRect),
              isTrue,
              reason: _why(
                f.s,
                'the text ${look.textRect} lies on its pill $box',
              ),
            );
            final Rect board = boardSquare(tester);
            expect(
              _inside(board, box),
              isTrue,
              reason: _why(f.s, 'the pill $box lies inside the board $board'),
            );
          } finally {
            await releaseGame(tester, f.s.drive);
          }
        },
      );

      testWidgets(
        'T2: ${locale.languageCode}, seat $mover\'s pill is rounded, filled '
        'with the seat colour, the text light and bold',
        (tester) async {
          final _Fix f = await _fixture(
            tester,
            name: 'T2 pill ${locale.languageCode} me=0 mover=$mover players=4',
            mover: mover,
            players: 4,
            locale: locale,
          );
          try {
            final int t0 = await _awaitFace(f);
            await _pumpTo(f.s, t0 + 1000);
            final Finder line = _lineFinder();
            final _Pill? pill = _pillOf(tester, line);
            expect(
              pill,
              isNotNull,
              reason: _why(f.s, 'a rounded filled box sits above the line'),
            );
            final Color? fill = pill!.decoration.color;
            expect(
              fill,
              isNotNull,
              reason: _why(f.s, 'the pill has a fill colour'),
            );
            expect(
              _sameRgb(fill!, LudoColors.seats[mover]),
              isTrue,
              reason: _why(
                f.s,
                'the pill fill $fill is seat $mover\'s colour '
                '${LudoColors.seats[mover]}',
              ),
            );
            final double radius =
                pill.decoration.borderRadius
                    ?.resolve(TextDirection.ltr)
                    .topLeft
                    .x ??
                0;
            expect(
              radius,
              greaterThanOrEqualTo(pill.rect.height / 2 - 1.0),
              reason: _why(
                f.s,
                'the corner radius $radius rounds the ends of a pill '
                '${pill.rect.height.toStringAsFixed(1)} px high',
              ),
            );
            final TextStyle? style = tester.widget<RichText>(line).text.style;
            expect(
              style?.fontWeight?.value ?? 0,
              greaterThanOrEqualTo(700),
              reason: _why(f.s, 'the text is bold, style $style'),
            );
            expect(
              style?.color,
              isNotNull,
              reason: _why(f.s, 'the text has its own colour, style $style'),
            );
            expect(
              style!.color!.computeLuminance(),
              greaterThanOrEqualTo(0.7),
              reason: _why(f.s, 'the text is light, colour ${style.color}'),
            );
          } finally {
            await releaseGame(tester, f.s.drive);
          }
        },
      );
    }
  }

  // -------------------------------------------------------------------
  // T2: near an edge, inside the board; large text, small screen.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[_en, _ar]) {
    for (final double scale in const <double>[1.0, 2.0]) {
      for (final int mover in const <int>[0, 1, 2, 3]) {
        testWidgets(
          'T2: 320x568, text scale $scale, ${locale.languageCode}: a gloat on '
          'seat $mover\'s yard throws nothing and the line stays inside the '
          'board on every frame',
          (tester) async {
            final _Fix f = await _fixture(
              tester,
              name:
                  'T2 small ${locale.languageCode} scale=$scale me=0 '
                  'mover=$mover players=4',
              mover: mover,
              players: 4,
              locale: locale,
              textScale: scale,
              surface: const Size(320, 568),
            );
            try {
              final Object? before = tester.takeException();
              expect(
                before,
                isNull,
                reason: _why(
                  f.s,
                  'fixture: the screen mounts at 320x568 and scale $scale '
                  'without an exception before any gloat',
                ),
              );
              await _pushCapture(f);
              final int t0 = await _awaitFace(f, step: kC468Frame);
              final Rect board = boardSquare(tester);
              final List<String> bad = <String>[];
              int seen = 0;
              while (f.s.clockMs <= t0 + _lifeMs + 100) {
                final Object? thrown = tester.takeException();
                if (thrown != null) {
                  bad.add('${f.s.clockMs - t0}ms: threw $thrown');
                }
                final _Look l = _look(f, t0);
                if (l.line) {
                  seen += 1;
                  final Rect shown = l.pillRect ?? l.textRect;
                  if (!_inside(board, shown)) {
                    bad.add(
                      '${l.age}ms: line rect $shown outside the board $board',
                    );
                  }
                  if (!_inside(board, l.textRect)) {
                    bad.add(
                      '${l.age}ms: text rect ${l.textRect} outside the '
                      'board $board',
                    );
                  }
                  final int most = scale > 1.0 ? 2 : 1;
                  if (l.lines > most) {
                    bad.add(
                      '${l.age}ms: "${l.text}" wraps to ${l.lines} lines, '
                      'at most $most at scale $scale',
                    );
                  }
                }
                if (!l.face && !l.line) {
                  break;
                }
                await _tick(f.s, kC468Frame);
              }
              expect(
                seen,
                greaterThan(50),
                reason: _why(f.s, 'fixture: the line was up for its life'),
              );
              expect(
                bad.take(6).toList(),
                isEmpty,
                reason: _why(
                  f.s,
                  'no exception and the line inside the board on every '
                  'frame; ${bad.length} violations, first: ${bad.take(6)}',
                ),
              );
            } finally {
              await releaseGame(tester, f.s.drive);
            }
          },
        );
      }
    }
  }

  // -------------------------------------------------------------------
  // T2: the face's pose.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[_en, _ar]) {
    testWidgets(
      'T2: ${locale.languageCode}: through the pop, wobble, hold and exit the '
      'line holds one opacity with the face, rises with it, and neither '
      'scales nor turns',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'T2 pose ${locale.languageCode} me=0 mover=2',
          mover: 2,
          locale: locale,
        );
        try {
          final int t0 = await _awaitFace(f);
          final List<_Look> looks = await _watch(
            f,
            origin: t0,
            until: t0 + _lifeMs + 200,
          );
          final String series = _series(looks);
          expect(
            looks.first.faceScale,
            lessThan(0.7),
            reason: _why(
              f.s,
              'fixture: the face starts its pop small (${looks.first}); '
              'otherwise "the line does not scale" measures nothing',
            ),
          );
          _expectTogether(f, looks);
          final _Look hold = looks.firstWhere((_Look l) => l.age >= 1000);
          for (final _Look l in looks.where(
            (_Look l) => l.line && l.age >= 350 && l.age <= 1300,
          )) {
            expect(
              l.lineOpacity,
              greaterThanOrEqualTo(0.98),
              reason: _why(
                f.s,
                'the line is fully opaque in the hold; ${l.age}ms; $series',
              ),
            );
          }
          final List<_Look> late = looks
              .where((_Look l) => l.line && l.age >= 1570)
              .toList();
          expect(late, isNotEmpty, reason: _why(f.s, 'still up at 1570 ms'));
          final double cell = cellSize(tester);
          final double risen = hold.lineCentre.dy - late.last.lineCentre.dy;
          expect(
            risen,
            inInclusiveRange(0.3 * cell, 0.6 * cell),
            reason: _why(
              f.s,
              'the line rose ${risen.toStringAsFixed(1)} px with the face by '
              '${late.last.age} ms; half a cell is '
              '${(cell / 2).toStringAsFixed(1)} px; $series',
            ),
          );
          expect(
            late.last.lineOpacity,
            lessThan(0.5),
            reason: _why(f.s, 'the line has faded by 1570 ms; $series'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'T2: with motion the line is present at 1500 ms and gone by 1610 ms, as '
    'the face is',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T2 life me=0 mover=0',
        mover: 0,
      );
      try {
        final int t0 = await _awaitFace(f);
        await _pumpTo(f.s, t0 + 1500);
        expect(
          _lineNow(f),
          isNotNull,
          reason: _why(f.s, 'the line is present at 1500 ms'),
        );
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: _why(f.s, 'the face is present at 1500 ms'));
        await _pumpTo(f.s, t0 + 1610);
        expect(
          _lineNow(f),
          isNull,
          reason: _why(f.s, 'the line is gone at 1610 ms'),
        );
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: _why(f.s, 'and so is the face'),
        );
        await f.s.pump(const Duration(milliseconds: 1500));
        expect(
          _lineNow(f),
          isNull,
          reason: _why(f.s, 'the line does not come back'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // T2 and C-579 D2: the early exit.
  // -------------------------------------------------------------------
  for (final (int me, int mover, int players, String view)
      in const <(int, int, int, String)>[
        (0, 2, 2, 'the capturer is the other player'),
        (0, 0, 2, 'the capturer is me'),
        (1, 0, 4, 'the capturer is a third seat'),
      ]) {
    testWidgets(
      'T2: $view (me $me, seat $mover): a rolled for the capturer at age '
      '300 ms takes the line out with the face: same frames, same fade, '
      'same lift',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'T2 yield me=$me mover=$mover players=$players',
          me: me,
          mover: mover,
          players: players,
        );
        try {
          await _pushCapture(f, extraRoll: true);
          final int t0 = await _awaitFace(f);
          await _pumpTo(f.s, t0 + 300);
          await _rollFor(f, mover);
          final int trigger = f.s.clockMs;
          final List<_Look> looks = await _watch(
            f,
            origin: trigger,
            until: trigger + _exitMs + 200,
          );
          final String series = _series(looks);
          _expectTogether(f, looks, what: 'early exit');
          final _Look gone = looks.last;
          expect(
            gone.face || gone.line,
            isFalse,
            reason: _why(
              f.s,
              'the face and the line are both gone 250 ms + a frame after '
              'the roll; $series',
            ),
          );
          expect(
            gone.age,
            inInclusiveRange(_exitMs - 15, _exitMs + 16),
            reason: _why(
              f.s,
              'both gone ${gone.age} ms after the roll, expected 250 give or take '
              'one frame; $series',
            ),
          );
          final _Look mid = looks.firstWhere((_Look l) => l.age >= 150);
          expect(
            mid.lineOpacity,
            inExclusiveRange(0.0, 1.0),
            reason: _why(
              f.s,
              'the line is mid-fade at the roll + 150 ms (the exit started '
              'at the roll); $series',
            ),
          );
          final double cell = cellSize(tester);
          final _Look last = looks.lastWhere((_Look l) => l.line);
          final double risen = looks.first.lineCentre.dy - last.lineCentre.dy;
          expect(
            risen,
            inInclusiveRange(0.3 * cell, 0.6 * cell),
            reason: _why(
              f.s,
              'the line lifted ${risen.toStringAsFixed(1)} px with the '
              'face; half a cell is ${(cell / 2).toStringAsFixed(1)} px; '
              '$series',
            ),
          );
          await f.s.pump(const Duration(milliseconds: 1500));
          expect(
            _lineNow(f),
            isNull,
            reason: _why(f.s, 'the line does not come back'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  // -------------------------------------------------------------------
  // T4: reduced motion.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[_en, _ar]) {
    testWidgets(
      'T4: reduced motion (${locale.languageCode}): the line is there on the '
      'first frame with the face, full opacity, no rise, gone with it at '
      '1600 ms',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'T4 reduced ${locale.languageCode} me=0 mover=2',
          mover: 2,
          locale: locale,
          reduced: true,
        );
        try {
          final int t0 = await _awaitFace(f);
          final List<_Look> looks = await _watch(
            f,
            origin: t0,
            until: t0 + _lifeMs + 200,
          );
          final String series = _series(looks);
          _expectTogether(f, looks, what: 'reduced');
          final _Look first = looks.first;
          expect(
            first.line,
            isTrue,
            reason: _why(f.s, 'the line shows on the first frame; $series'),
          );
          for (final _Look l in looks.where(
            (_Look l) => l.line && l.age <= 1500,
          )) {
            expect(
              l.lineOpacity,
              greaterThanOrEqualTo(0.99),
              reason: _why(
                f.s,
                'no fade under reduced motion; ${l.age}ms; $series',
              ),
            );
            expect(
              (l.lineCentre - first.lineCentre).distance,
              lessThan(0.5),
              reason: _why(
                f.s,
                'no rise under reduced motion; ${l.age}ms moved '
                '${(l.lineCentre - first.lineCentre).distance} px; $series',
              ),
            );
          }
          expect(
            looks.where((_Look l) => l.line).last.age,
            inInclusiveRange(1500, _lifeMs + 15),
            reason: _why(f.s, 'the line stays to the end of the life; $series'),
          );
          expect(
            looks.last.line || looks.last.face,
            isFalse,
            reason: _why(f.s, 'both gone at 1600 ms; $series'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'T4: reduced motion, early exit: the line stays put and full until the '
    'face is removed 250 ms after the roll, and goes with it',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T4 reduced yield me=0 mover=2',
        mover: 2,
        reduced: true,
      );
      try {
        await _pushCapture(f, extraRoll: true);
        final int t0 = await _awaitFace(f);
        await _pumpTo(f.s, t0 + 300);
        await _rollFor(f, 2);
        final int trigger = f.s.clockMs;
        final List<_Look> looks = await _watch(
          f,
          origin: trigger,
          until: trigger + _exitMs + 200,
        );
        final String series = _series(looks);
        _expectTogether(f, looks, what: 'reduced early exit');
        for (final _Look l in looks.where((_Look l) => l.line)) {
          expect(
            (l.lineCentre - looks.first.lineCentre).distance,
            lessThan(0.5),
            reason: _why(f.s, 'no rise; ${l.age}ms after the roll; $series'),
          );
        }
        expect(
          looks.last.line || looks.last.face,
          isFalse,
          reason: _why(f.s, 'both gone within 250 ms + a frame; $series'),
        );
        expect(
          looks.last.age,
          inInclusiveRange(_exitMs - 15, _exitMs + 16),
          reason: _why(f.s, 'both gone at the roll + 250 ms; $series'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // T3: one pick per serial.
  // -------------------------------------------------------------------
  testWidgets(
    'T3: one serial keeps its line across plain frames, a text scale change, '
    'a turn frame, another seat\'s roll and the capturer\'s yielding flip',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T3 same serial me=0 mover=2',
        mover: 2,
      );
      try {
        await _pushCapture(f, extraRoll: true);
        final int t0 = await _awaitFace(f);
        final String first = _lineNow(f)!;
        void same(String when) {
          expect(
            _lineNow(f),
            first,
            reason: _why(
              f.s,
              'the same gloat keeps "$first" $when (at ${f.s.clockMs - t0} '
              'ms of its life)',
            ),
          );
        }

        await _pumpTo(f.s, t0 + 100);
        same('over plain frames');
        await mountGame(f.tester, f.s.drive, textScale: 1.3);
        f.s.steps.add('remount at text scale 1.3');
        same('after the whole screen rebuilt at text scale 1.3');
        await _pumpTo(f.s, t0 + 250);
        same('before a turn frame');
        await _rollFor(f, 0);
        same('after seat 0 rolled');
        await _pumpTo(f.s, t0 + 450);
        same('after more frames');
        await _rollFor(f, 2);
        final int trigger = f.s.clockMs;
        same('on the frame the capturer rolled (the yielding flip)');
        int guard = 0;
        while (f.tester.any(f.face)) {
          same('while the face leaves on the yielding exit');
          await _tick(f.s);
          guard += 1;
          expect(
            guard,
            lessThan(80),
            reason: _why(
              f.s,
              'fixture: the face is gone within 400 ms of the roll at '
              '${trigger}ms',
            ),
          );
        }
        expect(
          _lineNow(f),
          isNull,
          reason: _why(f.s, 'the line is gone with the face'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets(
    'T3: a gloat that replaces another, from a different seat and from the '
    'same seat, draws one line and a different one',
    (tester) async {
      phoneSurface(tester);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: awaitRollTurn(2),
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: const <int>[3, 10, -1, -1]),
          seatJson(2, name: 'Bob', tokens: const <int>[3, 10, 48, 30]),
        ],
      );
      await mountGame(tester, drive);
      final Scn s = Scn('T3 replace', tester, drive);
      final _Fix f = _Fix(
        s,
        0,
        2,
        0,
        _en,
        2,
        false,
        const <Map<String, Object?>>[],
      );
      f.pushed = true;
      try {
        await s.push(
          'moved',
          movedFrame(
            2,
            0,
            3,
            9,
            captured: <Map<String, int>>[
              <String, int>{'seat': 0, 'token': 2},
            ],
          ),
        );
        final int t0 = await _awaitFace(f);
        final String first = _lineNow(f)!;
        await s.push('turn', turnFrame(0));
        await s.push(
          'moved',
          movedFrame(
            0,
            1,
            10,
            16,
            captured: <Map<String, int>>[
              <String, int>{'seat': 2, 'token': 3},
            ],
          ),
        );
        int guard = 0;
        while (true) {
          await _tick(s);
          if (gloatSeats(tester).contains(0)) {
            break;
          }
          guard += 1;
          expect(
            guard,
            lessThan(400),
            reason: _why(s, 'seat 0\'s capture gloats within 2 s'),
          );
          expect(
            _lineNow(f),
            anyOf(isNull, first),
            reason: _why(s, 'the first line stays until it is replaced'),
          );
        }
        expect(
          s.clockMs - t0,
          lessThan(1500),
          reason: _why(s, 'fixture: the first gloat was still up'),
        );
        final String second = _lineNow(f)!;
        expect(
          second,
          isNot(first),
          reason: _why(
            s,
            'the replacing gloat draws a new line, not "$first" again',
          ),
        );
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: _why(s, 'fixture: only seat 0\'s face is up'));
        final int upAt = s.clockMs;
        // Same seat again while this face is up: a fresh serial, a fresh pick.
        await s.push('turn', turnFrame(0));
        await s.push(
          'moved',
          movedFrame(
            0,
            0,
            3,
            9,
            captured: <Map<String, int>>[
              <String, int>{'seat': 2, 'token': 2},
            ],
          ),
        );
        String? third;
        guard = 0;
        while (third == null && guard < 400 && s.clockMs - upAt < 1500) {
          await _tick(s);
          guard += 1;
          final String? now = _lineNow(f);
          if (now != null && now != second) {
            third = now;
          }
        }
        expect(
          third,
          isNotNull,
          reason: _why(
            s,
            'a second gloat by the same seat while "$second" is up draws a '
            'different line within its walk; the line stayed "$second"',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // T5: semantics and pointer.
  // -------------------------------------------------------------------
  for (final bool mine in const <bool>[true, false]) {
    for (final Locale locale in const <Locale>[_en, _ar]) {
      testWidgets(
        'T5: ${locale.languageCode}, ${mine ? 'my' : 'their'} gloat: the '
        'line is not in the semantics tree and sits under IgnorePointer and '
        'ExcludeSemantics',
        (tester) async {
          final SemanticsHandle handle = tester.ensureSemantics();
          final _Fix f = await _fixture(
            tester,
            name: 'T5 semantics ${locale.languageCode} mine=$mine',
            mover: mine ? 0 : 2,
            locale: locale,
          );
          try {
            final int t0 = await _awaitFace(f);
            await _pumpTo(f.s, t0 + 600);
            final String line = _lineNow(f)!;
            await tester.pump();
            final List<String> hits = _semanticsMentioning(
              tester,
              _everyLine(),
            );
            expect(
              hits,
              isEmpty,
              reason: _why(
                f.s,
                'no semantics node carries a gloat line ("$line" is on '
                'screen); found $hits',
              ),
            );
            bool ignoring = false;
            bool excluding = false;
            tester.element(_lineFinder()).visitAncestorElements((
              Element ancestor,
            ) {
              final Widget w = ancestor.widget;
              if (w is IgnorePointer && w.ignoring) {
                ignoring = true;
              }
              if (w is ExcludeSemantics && w.excluding) {
                excluding = true;
              }
              return true;
            });
            expect(
              ignoring,
              isTrue,
              reason: _why(f.s, 'the line has an IgnorePointer above it'),
            );
            expect(
              excluding,
              isTrue,
              reason: _why(f.s, 'the line has an ExcludeSemantics above it'),
            );
            expect(
              tester.widget(f.face),
              isA<IgnorePointer>(),
              reason: _why(
                f.s,
                'capture-gloat-${f.mover} stays an IgnorePointer',
              ),
            );
            expect(
              find.descendant(
                of: f.face,
                matching: find.byType(ExcludeSemantics),
              ),
              findsWidgets,
              reason: _why(f.s, 'and keeps its ExcludeSemantics'),
            );
          } finally {
            handle.dispose();
            await releaseGame(tester, f.s.drive);
          }
        },
      );
    }
  }

  // -------------------------------------------------------------------
  // T6: unchanged.
  // -------------------------------------------------------------------
  testWidgets(
    'T6: the face, its life and the cue are as before: the captured seat '
    'hears gloat once at about 250 ms, the capturer never, and the face is '
    'gone at 1600 ms',
    (tester) async {
      for (final (int me, int expected) in const <(int, int)>[(0, 0), (2, 1)]) {
        final _Fix f = await _fixture(
          tester,
          name: 'T6 cue me=$me mover=0 players=4',
          me: me,
          mover: 0,
          players: 4,
        );
        try {
          final int t0 = await _awaitFace(f);
          expect(
            f.s.count(FeedbackCue.gloat),
            0,
            reason: _why(f.s, 'seat $me: no cue on the first frame'),
          );
          await _pumpTo(f.s, t0 + 200);
          expect(
            f.s.count(FeedbackCue.gloat),
            0,
            reason: _why(f.s, 'seat $me: no cue at 200 ms'),
          );
          await _pumpTo(f.s, t0 + 300);
          expect(
            f.s.count(FeedbackCue.gloat),
            expected,
            reason: _why(
              f.s,
              'seat $me hears the cue $expected time(s) by 300 ms',
            ),
          );
          await _pumpTo(f.s, t0 + 1500);
          expect(gloatSeats(tester), <int>[
            0,
          ], reason: _why(f.s, 'the face is up at 1500 ms'));
          await _pumpTo(f.s, t0 + 1610);
          expect(
            gloatSeats(tester),
            isEmpty,
            reason: _why(f.s, 'the face is gone at 1600 ms'),
          );
          expect(
            f.s.count(FeedbackCue.gloat),
            expected,
            reason: _why(f.s, 'the cue count stays $expected for seat $me'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      }
    },
  );

  testWidgets(
    'T6: the screen is unmounted 300 ms into a gloat: the line goes with it, '
    'nothing throws and no timer is left',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'T6 unmount me=0 mover=2',
        mover: 2,
      );
      final int t0 = await _awaitFace(f);
      await _pumpTo(f.s, t0 + 300);
      await releaseGame(tester, f.s.drive);
      await f.s.pump(const Duration(milliseconds: 2000));
      expect(
        _lineNow(f),
        isNull,
        reason: _why(f.s, 'no line after the screen is gone'),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: _why(f.s, 'nothing threw after the unmount'),
      );
    },
  );
}
