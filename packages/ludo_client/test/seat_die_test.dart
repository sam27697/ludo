// Screen proof for contract C-465: each seat's die sits at its own side of
// the board. A real GameScreen over RoomController and FakeTransport, every
// state a decoded wire frame, via support/roll_tray_harness.dart.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/die_cube.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_die.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/roll_tray_harness.dart';

const Duration _kFrame = Duration(milliseconds: 16);

/// Everything a throw takes from the frame to the last fade pixel, plus a
/// few frames of slack.
final Duration _kThrowTotal =
    kThrowTumble + kThrowRest + kThrowFade + _kFrame * 4;

const List<int> _yard = <int>[-1, -1, -1, -1];
const List<int> _oneOut = <int>[0, -1, -1, -1];

/// A scenario: the name, the frames pushed and the time pumped so far.
class _Scn {
  _Scn(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];

  String why(String expected) =>
      '$name | expected: $expected | replay: ${steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  Future<void> pump(Duration duration) async {
    steps.add('pump ${duration.inMilliseconds}ms');
    await _pumpFrames(tester, duration);
  }
}

Future<void> _pumpFrames(WidgetTester tester, Duration duration) async {
  Duration elapsed = Duration.zero;
  while (elapsed < duration) {
    final Duration remaining = duration - elapsed;
    final Duration step = remaining < _kFrame ? remaining : _kFrame;
    await tester.pump(step);
    elapsed += step;
  }
}

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

/// Two seats, 0 and 2. The opponent is called Bob in both views.
List<Map<String, Object?>> _pair({
  required int mySeat,
  List<int> mine = _yard,
  List<int> opponent = _yard,
}) {
  final int other = mySeat == 0 ? 2 : 0;
  final Map<int, Map<String, Object?>> bySeat = <int, Map<String, Object?>>{
    mySeat: seatJson(mySeat, name: 'Sam', tokens: mine),
    other: seatJson(other, name: 'Bob', tokens: opponent),
  };
  return <Map<String, Object?>>[bySeat[0]!, bySeat[2]!];
}

List<Map<String, Object?>> _quad({
  required int mySeat,
  Map<int, List<int>> tokens = const <int, List<int>>{},
}) => <Map<String, Object?>>[
  for (int seat = 0; seat < 4; seat++)
    seatJson(
      seat,
      name: seat == mySeat ? 'Sam' : _names[seat]!,
      tokens: tokens[seat] ?? _yard,
    ),
];

Map<String, Object?> _awaitRoll(int seat, {int k = 0, List<int>? queue}) =>
    turnJson(seat: seat, phase: 'await_roll', k: k, queue: queue);

Map<String, Object?> _rolledData(
  int seat,
  int value,
  int k, {
  List<int> legal = const <int>[0],
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _turnData(int seat, {List<int> queue = const <int>[]}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

Map<String, Object?> _movedData(int seat, int token, int from, int to) =>
    <String, Object?>{
      'seat': seat,
      'token': token,
      'from': from,
      'to': to,
      'captured': <Object?>[],
      'extra_roll': false,
    };

Future<RollTrayDrive> _mount(
  WidgetTester tester, {
  required Map<String, Object?> turn,
  required List<Map<String, Object?>> seats,
  int mySeat = 0,
  int players = 2,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool disableAnimations = false,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: mySeat,
    players: players,
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    textScale: textScale,
    disableAnimations: disableAnimations,
  );
  return drive;
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

double _cell(WidgetTester tester) => boardSquare(tester).width / 15;

Rect _quadrant(WidgetTester tester, int seat, int mySeat) =>
    yardQuadrantViewRect(boardSquare(tester), seat, mySeat);

void _expectNear(double actual, double expected, double tol, String reason) {
  expect(
    actual,
    closeTo(expected, tol),
    reason: '$reason (actual $actual, wanted $expected +- $tol)',
  );
}

void _expectInside(Rect outer, Rect inner, String reason, {double slack = 1}) {
  final Rect grown = outer.inflate(slack);
  expect(
    grown.contains(inner.topLeft) && grown.contains(inner.bottomRight),
    isTrue,
    reason: '$reason (inner $inner not inside $outer +- $slack)',
  );
}

/// The opacity a seat die paints at: the product of every Opacity,
/// AnimatedOpacity and FadeTransition on the key's own element and above
/// it, up to the LudoBoard. Nothing wrapping it is full opacity. A wrapper
/// below the key is not read (the contract puts the key on the die's root).
double _opacityOf(_Scn s, Key key) {
  final WidgetTester tester = s.tester;
  expect(
    find.byKey(key),
    findsOneWidget,
    reason: s.why('$key on the board, to read its opacity'),
  );
  double product = 1.0;
  double read(Widget widget) {
    if (widget is Opacity) {
      return widget.opacity;
    }
    if (widget is AnimatedOpacity) {
      return widget.opacity;
    }
    if (widget is FadeTransition) {
      return widget.opacity.value;
    }
    return 1.0;
  }

  final Element start = tester.element(find.byKey(key));
  product *= read(start.widget);
  start.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is LudoBoard) {
      return false;
    }
    product *= read(ancestor.widget);
    return true;
  });
  return product;
}

DieCube _cubeIn(WidgetTester tester, Key key) => tester.widget<DieCube>(
  find.descendant(of: find.byKey(key), matching: find.byType(DieCube)),
);

bool _sameMatrix(Matrix4 a, Matrix4 b) {
  for (int i = 0; i < 16; i++) {
    if ((a.storage[i] - b.storage[i]).abs() > 1e-6) {
      return false;
    }
  }
  return true;
}

/// How many of the cube's faces point at the viewer under [rotation].
int _visibleFaces(Matrix4 rotation) {
  int count = 0;
  for (final (double, double, double) n in kFaceNormals.values) {
    final double z =
        rotation.entry(2, 0) * n.$1 +
        rotation.entry(2, 1) * n.$2 +
        rotation.entry(2, 2) * n.$3;
    if (z > 0.02) {
      count += 1;
    }
  }
  return count;
}

/// Which seat die key is on screen for [seat]: its face, -1 for the idle
/// pose, null for no die.
int? _seatDieShows(WidgetTester tester, int seat) {
  final List<int> faces = <int>[
    for (int f = 1; f <= 6; f++)
      if (tester.any(find.byKey(seatDieFaceKey(seat, f)))) f,
  ];
  final bool idle = tester.any(find.byKey(seatDieIdleKey(seat)));
  if (faces.length + (idle ? 1 : 0) > 1) {
    fail('seat $seat die shows more than one state: faces $faces idle $idle');
  }
  if (faces.isNotEmpty) {
    return faces.single;
  }
  return idle ? -1 : null;
}

void _expectSeatDie(_Scn s, int seat, int? face, String when) {
  final int? shown = _seatDieShows(s.tester, seat);
  final int wanted = face ?? -1;
  expect(
    shown,
    wanted,
    reason: s.why(
      '$when: seat $seat die shows ${face ?? 'the idle pose'} '
      '(-1 = idle)',
    ),
  );
  expect(
    find.byKey(seatDieKey(seat)),
    findsOneWidget,
    reason: s.why('$when: board-seat-die-$seat is on the board once'),
  );
}

/// Index of the board Stack child that holds [target].
int _slot(WidgetTester tester, Element boardStack, Finder target, String who) {
  expect(target, findsOneWidget, reason: '$who is on the board');
  final Element start = tester.element(target);
  Element previous = start;
  int? found;
  start.visitAncestorElements((Element ancestor) {
    if (identical(ancestor, boardStack)) {
      int index = 0;
      ancestor.visitChildElements((Element child) {
        if (identical(child, previous)) {
          found = index;
        }
        index += 1;
      });
      return false;
    }
    previous = ancestor;
    return true;
  });
  expect(found, isNotNull, reason: '$who is not a layer of the board stack');
  return found!;
}

Element _boardStack(WidgetTester tester) {
  final Element token = tester.element(find.byKey(const Key('token-2-0')));
  Element? stack;
  token.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is Stack) {
      stack = ancestor;
      return false;
    }
    return true;
  });
  return stack!;
}

List<String> _semanticsLabels(WidgetTester tester) {
  // The root pipeline owner owns no render tree; semantics live on the
  // view's own owner.
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final List<String> labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty) {
      labels.add(node.label);
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return labels;
}

/// The circle a drawn yard token paints, as its square. `token-<s>-<i>` is
/// the Semantics around the disc, sized exactly to it.
Rect _disc(WidgetTester tester, int seat, int token) =>
    tester.getRect(find.byKey(Key('token-$seat-$token')));

bool _circleTouchesRect(Rect disc, Rect rect) {
  final Offset c = disc.center;
  final double dx = math.max(
    rect.left - c.dx,
    math.max(0.0, c.dx - rect.right),
  );
  final double dy = math.max(
    rect.top - c.dy,
    math.max(0.0, c.dy - rect.bottom),
  );
  return math.sqrt(dx * dx + dy * dy) < disc.width / 2;
}

/// C-468 D6's FeedbackCue.dieLand, looked up by name so this file still
/// compiles, and its other cases still run, on a tree where the cue does
/// not exist yet; only the case that uses it fails there (order 469).
FeedbackCue get _dieLand => FeedbackCue.values.byName('dieLand');

void main() {
  // -------------------------------------------------------------------
  // D1: the big die under the board is only ever mine.
  // -------------------------------------------------------------------
  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    testWidgets(
      'D1: on seat $opp\'s turn my big die (seat $me) is the idle art in '
      'my colour, not enabled, before, during and after the throw lands',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: me,
          turn: _awaitRoll(opp),
          seats: _pair(mySeat: me, mine: _oneOut, opponent: _oneOut),
        );
        final _Scn s = _Scn('D1 me=$me opp=$opp', tester, drive);
        try {
          void expectMine(String when) {
            final GameDie die = tester.widget<GameDie>(find.byType(GameDie));
            expect(
              die.seatColor,
              LudoColors.seats[me],
              reason: s.why('$when: big die edge is seat $me\'s colour'),
            );
            expect(
              die.face,
              isNull,
              reason: s.why('$when: big die has no face on seat $opp\'s turn'),
            );
            expect(
              die.enabled,
              isFalse,
              reason: s.why('$when: big die widget not enabled'),
            );
            expect(
              find.byKey(idleArtKey),
              findsOneWidget,
              reason: s.why('$when: game-die-idle-art on the big die'),
            );
            for (int f = 1; f <= 6; f++) {
              expect(
                find.byKey(bigFaceKey(f)),
                findsNothing,
                reason: s.why('$when: no game-die-face-$f on the big die'),
              );
            }
            expect(
              tester
                  .getSemantics(find.byKey(bigDieKey))
                  .flagsCollection
                  .isEnabled,
              Tristate.isFalse,
              reason: s.why('$when: game-die semantics not enabled'),
            );
          }

          expectMine('before the roll');
          await s.push('rolled', _rolledData(opp, 5, 1));
          expectMine('on the rolled frame');
          Duration elapsed = Duration.zero;
          while (elapsed < _kThrowTotal) {
            await tester.pump(_kFrame);
            elapsed += _kFrame;
            expectMine('${elapsed.inMilliseconds}ms into the throw');
          }
          expect(
            find.byKey(opponentThrowKey(opp)),
            findsNothing,
            reason: s.why('the throw is over by $_kThrowTotal'),
          );
          expectMine('after the throw');
        } finally {
          handle.dispose();
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D1: on my own turn the big die still shows my face and my colour, '
    'and rolls on tap',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(0),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D1 own turn', tester, drive);
      try {
        expect(
          tester.widget<GameDie>(find.byType(GameDie)).enabled,
          isTrue,
          reason: s.why('my await_roll: the big die is enabled'),
        );
        await s.push('rolled', _rolledData(0, 4, 1, legal: const <int>[0]));
        expect(
          find.byKey(bigFaceKey(4)),
          findsOneWidget,
          reason: s.why('my rolled 4: game-die-face-4'),
        );
        expect(
          tester.widget<GameDie>(find.byType(GameDie)).seatColor,
          LudoColors.seats[0],
          reason: s.why('my turn: my colour'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('D1.4: on seat 2\'s turn after its 5 landed there is no '
      'game-screen-dice-value and no semantics label reads the 5; on my turn '
      'with a 4 the node exists with the 4 label', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final RollTrayDrive drive = await _mount(
      tester,
      turn: _awaitRoll(2),
      seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
    );
    final _Scn s = _Scn('D1.4', tester, drive);
    try {
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byKey(bigDieKey)),
      );
      final String five = loc.gameDieValue(5);
      await s.push('rolled', _rolledData(2, 5, 1));
      await s.pump(kThrowTumble + _kFrame * 2);
      expect(
        find.byKey(opponentThrowLandedKey(2, 5)),
        findsOneWidget,
        reason: s.why('fixture: the throw has landed'),
      );
      for (final String when in <String>['landed', 'after the throw']) {
        expect(
          find.byKey(diceValueKey),
          findsNothing,
          reason: s.why('$when: no game-screen-dice-value on seat 2\'s turn'),
        );
        expect(
          _semanticsLabels(tester).where((String l) => l.contains(five)),
          isEmpty,
          reason: s.why('$when: no semantics label "$five" anywhere'),
        );
        await s.pump(_kThrowTotal);
      }

      await s.push('moved', _movedData(2, 0, 0, 5));
      await s.push('turn', _turnData(0));
      await s.push('rolled', _rolledData(0, 4, 1));
      expect(
        find.byKey(diceValueKey),
        findsOneWidget,
        reason: s.why('my turn with value 4: the node exists'),
      );
      expect(
        tester.widget<Semantics>(find.byKey(diceValueKey)).properties.label,
        loc.gameDieValue(4),
        reason: s.why('my turn with value 4: label "${loc.gameDieValue(4)}"'),
      );
    } finally {
      handle.dispose();
      await releaseGame(tester, drive);
    }
  });

  // -------------------------------------------------------------------
  // D2: placement.
  // -------------------------------------------------------------------
  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    testWidgets(
      'D2: two seats from seat $me: one seat die for seat $opp at the '
      'centre of its yard quadrant, none for me',
      (tester) async {
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: me,
          turn: _awaitRoll(me),
          seats: _pair(mySeat: me),
        );
        final _Scn s = _Scn('D2 place me=$me opp=$opp', tester, drive);
        try {
          final Rect mine = _quadrant(tester, me, me);
          final Rect board = boardSquare(tester);
          expect(
            mine.left == board.left && mine.bottom == board.bottom,
            isTrue,
            reason: s.why('fixture: my yard $mine is bottom-left of $board'),
          );
          final Rect quadrant = _quadrant(tester, opp, me);
          expect(
            find.byKey(seatDieKey(opp)),
            findsOneWidget,
            reason: s.why('a seat die for seat $opp'),
          );
          final Rect die = tester.getRect(find.byKey(seatDieKey(opp)));
          expect(
            quadrant.contains(die.center),
            isTrue,
            reason: s.why('die centre ${die.center} inside quadrant $quadrant'),
          );
          _expectNear(
            (die.center - quadrant.center).distance,
            0,
            1,
            s.why('die centre at the quadrant centre ${quadrant.center}'),
          );
          _expectNear(
            die.width,
            2 * _cell(tester),
            1,
            s.why('die width is 2 cells'),
          );
          _expectNear(
            die.height,
            2 * _cell(tester),
            1,
            s.why('die height is 2 cells'),
          );
          expect(
            find.byKey(seatDieKey(me)),
            findsNothing,
            reason: s.why('no seat die for my own seat $me'),
          );
          expect(
            find.byKey(seatDieIdleKey(me)),
            findsNothing,
            reason: s.why('no idle seat die for my own seat $me'),
          );
          for (int f = 1; f <= 6; f++) {
            expect(
              find.byKey(seatDieFaceKey(me, f)),
              findsNothing,
              reason: s.why('no face seat die for my own seat $me'),
            );
          }
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D2: four seats from seat 1: three seat dice, each in its own yard '
    'quadrant, none for seat 1, all the one idle pose in its own colour',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn('D2 four seats from 1', tester, drive);
      try {
        expect(
          find.byKey(seatDieKey(1)),
          findsNothing,
          reason: s.why('no seat die for my own seat 1'),
        );
        Matrix4? idlePose;
        for (final int seat in const <int>[0, 2, 3]) {
          final Rect quadrant = _quadrant(tester, seat, 1);
          expect(
            find.byKey(seatDieKey(seat)),
            findsOneWidget,
            reason: s.why('a seat die for seat $seat'),
          );
          final Rect die = tester.getRect(find.byKey(seatDieKey(seat)));
          _expectNear(
            (die.center - quadrant.center).distance,
            0,
            1,
            s.why('seat $seat die at its quadrant centre ${quadrant.center}'),
          );
          expect(
            find.byKey(seatDieIdleKey(seat)),
            findsOneWidget,
            reason: s.why('seat $seat die has not rolled: idle pose'),
          );
          final DieCube cube = _cubeIn(tester, seatDieKey(seat));
          expect(
            cube.edgeColor,
            LudoColors.seats[seat],
            reason: s.why('seat $seat die is edged in its own colour'),
          );
          expect(
            _visibleFaces(cube.rotation),
            3,
            reason: s.why('seat $seat idle pose shows three faces at once'),
          );
          if (idlePose != null) {
            expect(
              _sameMatrix(idlePose, cube.rotation),
              isTrue,
              reason: s.why('every idle seat die uses the one fixed pose'),
            );
          }
          idlePose = cube.rotation;
        }
        for (int face = 1; face <= 6; face++) {
          expect(
            _sameMatrix(idlePose!, restingRotationFor(face)),
            isFalse,
            reason: s.why('the idle pose is not the resting pose of $face'),
          );
        }
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: the seat die sits above the yard glow and name chip and below the '
    'tokens and the thrown die',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D2 layer', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        await s.pump(kThrowTumble + _kFrame * 2);
        for (final Key key in <Key>[
          seatDieKey(2),
          const Key('board-turn-yard-2'),
          const Key('board-seat-name-2'),
          const Key('token-2-0'),
          const Key('token-0-0'),
          opponentThrowKey(2),
        ]) {
          expect(
            find.byKey(key),
            findsOneWidget,
            reason: s.why('$key is a layer of the board'),
          );
        }
        final Element stack = _boardStack(tester);
        final int die = _slot(
          tester,
          stack,
          find.byKey(seatDieKey(2)),
          'board-seat-die-2',
        );
        int below(Key key) => _slot(tester, stack, find.byKey(key), '$key');
        expect(
          below(const Key('board-turn-yard-2')),
          lessThan(die),
          reason: s.why('the yard glow is under the seat die'),
        );
        expect(
          below(const Key('board-seat-name-2')),
          lessThan(die),
          reason: s.why('the name chip is under the seat die'),
        );
        expect(
          below(const Key('token-2-0')),
          greaterThan(die),
          reason: s.why('seat 2\'s tokens paint over its die'),
        );
        expect(
          below(const Key('token-0-0')),
          greaterThan(die),
          reason: s.why('my tokens paint over the seat die'),
        );
        expect(
          below(opponentThrowKey(2)),
          greaterThan(die),
          reason: s.why('the thrown die paints over the seat die'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D2: emphasis and memory.
  // -------------------------------------------------------------------
  testWidgets(
    'D2: a seat die is at full opacity on its seat\'s turn and 0.45 off it '
    '(opacity read from the Opacity, AnimatedOpacity or FadeTransition on '
    'or above its key)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('D2 emphasis', tester, drive);
      try {
        await s.pump(const Duration(milliseconds: 800));
        _expectNear(
          _opacityOf(s, seatDieKey(2)),
          1.0,
          0.01,
          s.why('seat 2 holds the turn: full opacity'),
        );
        await s.push('turn', _turnData(0));
        await s.pump(const Duration(milliseconds: 800));
        _expectNear(
          _opacityOf(s, seatDieKey(2)),
          0.45,
          0.01,
          s.why('my turn: seat 2 die at 0.45'),
        );
        await s.push('turn', _turnData(2));
        await s.pump(const Duration(milliseconds: 800));
        _expectNear(
          _opacityOf(s, seatDieKey(2)),
          1.0,
          0.01,
          s.why('seat 2\'s turn again: full opacity'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: in four seats only the turn seat\'s die is at full opacity',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(2),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn('D2 emphasis four seats', tester, drive);
      try {
        await s.pump(const Duration(milliseconds: 800));
        const Map<int, double> wanted = <int, double>{0: 0.45, 2: 1.0, 3: 0.45};
        for (final MapEntry<int, double> entry in wanted.entries) {
          _expectNear(
            _opacityOf(s, seatDieKey(entry.key)),
            entry.value,
            0.01,
            s.why('turn is seat 2\'s: seat ${entry.key} die opacity'),
          );
        }
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: idle pose before seat 2 has rolled, and it never shows a face',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('D2 idle first', tester, drive);
      try {
        _expectSeatDie(s, 2, null, 'seat 2 has not rolled');
        await s.push('turn', _turnData(0));
        _expectSeatDie(s, 2, null, 'my turn, seat 2 still has not rolled');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: the seat die rests at the pose of its face, is absent while the '
    'throw tumbles, keeps the face when the turn passes (at 0.45) and '
    'through my own roll',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D2 memory', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('fixture: the throw is tumbling'),
        );
        expect(
          find.byKey(seatDieKey(2)),
          findsNothing,
          reason: s.why('no seat die while its throw tumbles'),
        );
        await s.pump(kThrowTumble + _kFrame * 2);
        _expectSeatDie(s, 2, 5, 'throw landed');
        expect(
          _sameMatrix(
            _cubeIn(tester, seatDieKey(2)).rotation,
            restingRotationFor(5),
          ),
          isTrue,
          reason: s.why('the seat die rests at restingRotationFor(5)'),
        );
        expect(
          _cubeIn(tester, seatDieKey(2)).edgeColor,
          LudoColors.seats[2],
          reason: s.why('the seat die is edged in seat 2\'s colour'),
        );
        await s.pump(_kThrowTotal);
        _expectSeatDie(s, 2, 5, 'throw over, seat 2 still holds the turn');
        _expectNear(
          _opacityOf(s, seatDieKey(2)),
          1.0,
          0.01,
          s.why('seat 2 holds the turn: full opacity'),
        );

        await s.push('moved', _movedData(2, 0, 0, 5));
        await s.push('turn', _turnData(0));
        await s.pump(const Duration(milliseconds: 800));
        _expectSeatDie(s, 2, 5, 'the turn passed to me');
        _expectNear(
          _opacityOf(s, seatDieKey(2)),
          0.45,
          0.01,
          s.why('off its turn: 0.45'),
        );

        await s.push('rolled', _rolledData(0, 3, 1));
        await s.pump(const Duration(milliseconds: 800));
        _expectSeatDie(s, 2, 5, 'after my own roll of 3');
        expect(
          find.byKey(bigFaceKey(3)),
          findsOneWidget,
          reason: s.why('my own roll shows on my big die'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: a remembered face is forgotten when its seat\'s next turn begins',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D2 next turn', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        await s.pump(_kThrowTotal);
        await s.push('moved', _movedData(2, 0, 0, 5));
        await s.push('turn', _turnData(0));
        _expectSeatDie(s, 2, 5, 'seat 2 passed the turn');
        await s.push('turn', _turnData(2));
        _expectSeatDie(s, 2, null, 'seat 2\'s next turn, nothing rolled yet');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: a resync snapshot whose recent_rolls is not an append forgets '
    'the remembered face',
    (tester) async {
      final List<Map<String, Object?>> seats = _pair(
        mySeat: 0,
        mine: _oneOut,
        opponent: _oneOut,
      );
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: seats,
      );
      final _Scn s = _Scn('D2 resync', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        await s.pump(_kThrowTotal);
        await s.push('moved', _movedData(2, 0, 0, 5));
        await s.push('turn', _turnData(0));
        _expectSeatDie(s, 2, 5, 'before the resync');
        await s.push('room', roomData(seats: seats, turn: _awaitRoll(0, k: 4)));
        _expectSeatDie(s, 2, null, 'after a snapshot that is not an append');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: a snapshot mounted on seat 2\'s awaitMove shows turn.value on its '
    'die with no throw',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: turnJson(
          seat: 2,
          phase: 'await_move',
          k: 1,
          value: 4,
          legal: const <int>[0],
          queue: const <int>[4],
          legalByFace: <Map<String, Object?>>[
            faceLegal(4, const <int>[0]),
          ],
        ),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D2 mounted awaitMove', tester, drive);
      try {
        _expectSeatDie(s, 2, 4, 'mounted on seat 2\'s awaitMove value 4');
        expect(
          find.byKey(opponentThrowKey(2)),
          findsNothing,
          reason: s.why('a snapshot starts no throw'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D2: in four seats each die remembers only its own seat\'s roll',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(
          mySeat: 1,
          tokens: const <int, List<int>>{0: _oneOut, 2: _oneOut, 3: _oneOut},
        ),
      );
      final _Scn s = _Scn('D2 four seats memory', tester, drive);
      try {
        await s.push('rolled', _rolledData(3, 4, 1));
        await s.pump(_kThrowTotal);
        _expectSeatDie(s, 3, 4, 'seat 3 rolled 4');
        _expectSeatDie(s, 2, null, 'seat 2 has not rolled');
        _expectSeatDie(s, 0, null, 'seat 0 has not rolled');
        await s.push('moved', _movedData(3, 0, 0, 4));
        await s.push('turn', _turnData(0));
        await s.push('rolled', _rolledData(0, 2, 1));
        await s.pump(_kThrowTotal);
        _expectSeatDie(s, 0, 2, 'seat 0 rolled 2');
        _expectSeatDie(s, 3, 4, 'seat 3 keeps its 4');
        _expectSeatDie(s, 2, null, 'seat 2 still has not rolled');
        _expectNear(
          _opacityOf(s, seatDieKey(3)),
          0.45,
          0.01,
          s.why('seat 3 is off its turn'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D2: never over a yard token's disc, at 360 wide and at 200 percent.
  // -------------------------------------------------------------------
  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    for (final double scale in const <double>[1.0, 2.0]) {
      testWidgets(
        'D2: at 360x800 and text scale $scale seat $opp\'s die (seen from '
        '$me) overlaps none of its four yard token discs',
        (tester) async {
          _phone(tester);
          final RollTrayDrive drive = await _mount(
            tester,
            mySeat: me,
            textScale: scale,
            turn: _awaitRoll(opp),
            seats: _pair(mySeat: me),
          );
          final _Scn s = _Scn('D2 overlap me=$me scale=$scale', tester, drive);
          try {
            expect(
              find.byKey(seatDieKey(opp)),
              findsOneWidget,
              reason: s.why('a seat die for seat $opp'),
            );
            final Rect die = tester.getRect(find.byKey(seatDieKey(opp)));
            for (int token = 0; token < 4; token++) {
              final Rect disc = _disc(tester, opp, token);
              expect(
                _circleTouchesRect(disc, die),
                isFalse,
                reason: s.why(
                  'die $die clear of seat $opp token $token disc $disc',
                ),
              );
            }
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  }

  // -------------------------------------------------------------------
  // D3: the throw lands on the seat die.
  // -------------------------------------------------------------------
  for (final (int me, int opp, bool phone) in const <(int, int, bool)>[
    (0, 2, false),
    (2, 0, false),
    (0, 2, true),
    (2, 0, true),
  ]) {
    testWidgets(
      'D3: seat $opp\'s throw (seen from $me, ${phone ? '360x800' : 'default'}) '
      'flies inside its quadrant at 2 cells, lands on its seat die centre at '
      'the same size, and the seat die is absent while it tumbles',
      (tester) async {
        if (phone) {
          _phone(tester);
        }
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: me,
          turn: _awaitRoll(opp),
          seats: _pair(mySeat: me, mine: _oneOut, opponent: _oneOut),
        );
        final _Scn s = _Scn('D3 me=$me opp=$opp phone=$phone', tester, drive);
        try {
          final Rect quadrant = _quadrant(tester, opp, me);
          final double cell = _cell(tester);
          await s.push('rolled', _rolledData(opp, 5, 1));
          expect(
            find.byKey(opponentThrowTumblingKey(opp)),
            findsOneWidget,
            reason: s.why('fixture: tumbling'),
          );
          final Rect first = tester.getRect(find.byKey(opponentThrowKey(opp)));
          final Offset corner = Offset(
            quadrant.center.dx < boardSquare(tester).center.dx
                ? quadrant.left
                : quadrant.right,
            quadrant.center.dy < boardSquare(tester).center.dy
                ? quadrant.top
                : quadrant.bottom,
          );
          expect(
            (first.center - corner).distance,
            lessThan((first.center - quadrant.center).distance),
            reason: s.why(
              'the throw starts at seat $opp\'s outer corner $corner, '
              'not at the middle (first centre ${first.center})',
            ),
          );
          Duration elapsed = Duration.zero;
          while (tester.any(find.byKey(opponentThrowTumblingKey(opp)))) {
            expect(
              elapsed,
              lessThan(kThrowTumble + _kFrame * 3),
              reason: s.why('the tumble ends by kThrowTumble + 3 frames'),
            );
            final Rect flight = tester.getRect(
              find.byKey(opponentThrowKey(opp)),
            );
            _expectInside(
              quadrant,
              Rect.fromCenter(center: flight.center, width: 0, height: 0),
              s.why('flight centre inside seat $opp quadrant at $elapsed'),
            );
            _expectNear(
              flight.width,
              2 * cell,
              1,
              s.why('flight size is 2 cells at $elapsed'),
            );
            expect(
              find.byKey(seatDieKey(opp)),
              findsNothing,
              reason: s.why('no seat die while tumbling, at $elapsed'),
            );
            await tester.pump(_kFrame);
            elapsed += _kFrame;
          }
          s.steps.add('pump ${elapsed.inMilliseconds}ms until tumble ended');
          expect(
            find.byKey(opponentThrowLandedKey(opp, 5)),
            findsOneWidget,
            reason: s.why('the throw has landed on 5'),
          );
          expect(
            find.byKey(opponentThrowTumblingKey(opp)),
            findsNothing,
            reason: s.why('no longer tumbling'),
          );
          expect(
            find.byKey(seatDieFaceKey(opp, 5)),
            findsOneWidget,
            reason: s.why('seat die drawn under the landed throw with 5'),
          );
          final Rect landed = tester.getRect(
            find.byKey(opponentThrowLandedKey(opp, 5)),
          );
          final Rect die = tester.getRect(find.byKey(seatDieKey(opp)));
          _expectNear(
            (landed.center - die.center).distance,
            0,
            1,
            s.why('landed centre ${landed.center} on die centre ${die.center}'),
          );
          _expectNear(
            (landed.center - quadrant.center).distance,
            0,
            1,
            s.why('landed centre on quadrant centre ${quadrant.center}'),
          );
          _expectNear(
            landed.width,
            die.width,
            1,
            s.why('landed and seat die widths'),
          );
          _expectNear(
            landed.height,
            die.height,
            1,
            s.why('landed and seat die heights'),
          );
          _expectInside(quadrant, landed, s.why('landed die inside quadrant'));
          _expectInside(quadrant, die, s.why('seat die inside quadrant'));
          expect(
            _sameMatrix(
              _cubeIn(tester, opponentThrowLandedKey(opp, 5)).rotation,
              _cubeIn(tester, seatDieKey(opp)).rotation,
            ),
            isTrue,
            reason: s.why('overlay and seat die share one pose'),
          );

          await s.pump(kThrowRest + kThrowFade + _kFrame * 2);
          expect(
            find.byKey(opponentThrowKey(opp)),
            findsNothing,
            reason: s.why('the overlay is gone'),
          );
          final Rect after = tester.getRect(find.byKey(seatDieKey(opp)));
          _expectNear(
            (after.center - die.center).distance,
            0,
            0.5,
            s.why('the seat die did not move when the overlay left'),
          );
          expect(
            find.byKey(seatDieFaceKey(opp, 5)),
            findsOneWidget,
            reason: s.why('the seat die is what remains, on 5'),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D3: under reduced motion the first frame is already landed on the seat '
    'die centre, with the seat die drawn',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        disableAnimations: true,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D3 reduced motion', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        expect(
          find.byKey(opponentThrowLandedKey(2, 5)),
          findsOneWidget,
          reason: s.why('landed on the first frame'),
        );
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsNothing,
          reason: s.why('never tumbling'),
        );
        expect(
          find.byKey(seatDieFaceKey(2, 5)),
          findsOneWidget,
          reason: s.why('the seat die is drawn on the first frame'),
        );
        final Rect quadrant = _quadrant(tester, 2, 0);
        final Rect landed = tester.getRect(
          find.byKey(opponentThrowLandedKey(2, 5)),
        );
        final Rect die = tester.getRect(find.byKey(seatDieKey(2)));
        _expectNear(
          (landed.center - die.center).distance,
          0,
          1,
          s.why('landed centre on the seat die centre'),
        );
        _expectNear(
          (landed.center - quadrant.center).distance,
          0,
          1,
          s.why('landed centre on the quadrant centre'),
        );
        _expectNear(landed.width, die.width, 1, s.why('equal sizes'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D3: two queued throws: the seat die stays absent while the second '
    'tumbles and shows the second face once it lands',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2, queue: const <int>[]),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D3 two throws', tester, drive);
      try {
        await s.push(
          'rolled',
          _rolledData(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
        );
        await s.push(
          'rolled',
          _rolledData(
            2,
            3,
            2,
            queue: const <int>[6, 3],
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[0]),
              faceLegal(3, const <int>[0]),
            ],
          ),
        );
        await s.pump(kThrowFast);
        await s.pump(_kFrame);
        expect(
          find.byKey(opponentThrowLandedKey(2, 6)),
          findsOneWidget,
          reason: s.why('fixture: the first throw rests on 6'),
        );
        _expectSeatDie(s, 2, 6, 'first throw resting');
        await s.pump(kThrowFast);
        await s.pump(_kFrame);
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('fixture: the second throw is tumbling'),
        );
        expect(
          find.byKey(seatDieKey(2)),
          findsNothing,
          reason: s.why('no seat die while the second throw tumbles'),
        );
        await s.pump(kThrowTumble);
        await s.pump(_kFrame);
        expect(
          find.byKey(opponentThrowLandedKey(2, 3)),
          findsOneWidget,
          reason: s.why('fixture: the second throw landed on 3'),
        );
        _expectSeatDie(s, 2, 3, 'second throw landed');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D4: the roll record goes where its die is.
  // -------------------------------------------------------------------
  Future<void> pushQueueSixThree(_Scn s) async {
    await s.push(
      'rolled',
      _rolledData(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
    );
    await s.push('turn', _turnData(2, queue: const <int>[6]));
    await s.push(
      'rolled',
      _rolledData(
        2,
        3,
        2,
        queue: const <int>[6, 3],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0]),
          faceLegal(3, const <int>[0]),
        ],
      ),
    );
  }

  testWidgets('D4: seat 2\'s queue [6, 3] is drawn on the board in its yard\'s '
      'track-side row, with the C-462 tile keys, and nothing under the board', (
    tester,
  ) async {
    _phone(tester);
    final RollTrayDrive drive = await _mount(
      tester,
      turn: _awaitRoll(2),
      seats: _pair(mySeat: 0, mine: _oneOut, opponent: _yard),
    );
    final _Scn s = _Scn('D4 seat 2 record', tester, drive);
    try {
      await pushQueueSixThree(s);
      await s.pump(_kThrowTotal + kThrowFast * 2);
      expect(
        find.byKey(seatRecordKey(2)),
        findsOneWidget,
        reason: s.why('board-seat-record-2 on the board'),
      );
      expect(
        find.byKey(rollTrayKey),
        findsNothing,
        reason: s.why('game-roll-tray is not under the board'),
      );
      final Rect board = boardSquare(tester);
      final double cell = board.width / 15;
      final Rect quadrant = _quadrant(tester, 2, 0);
      final Rect record = tester.getRect(find.byKey(seatRecordKey(2)));
      _expectInside(quadrant, record, s.why('record inside seat 2 quadrant'));
      final bool topYard = quadrant.top <= board.top + 0.5;
      final double rowTop = topYard ? quadrant.bottom - cell : quadrant.top;
      _expectInside(
        Rect.fromLTWH(quadrant.left, rowTop, quadrant.width, cell),
        record,
        s.why(
          'record in the ${topYard ? 'bottom' : 'top'} row of the yard '
          '(the row on the track side)',
        ),
      );
      expect(
        record.height,
        lessThanOrEqualTo(cell * 0.9 + 1),
        reason: s.why('record height ${record.height} <= row less inset'),
      );
      expect(
        record.width,
        lessThanOrEqualTo(quadrant.width + 1),
        reason: s.why('record no wider than the yard'),
      );
      _expectNear(
        record.center.dx,
        quadrant.center.dx,
        1,
        s.why('record centred across the yard'),
      );
      final Rect chip = tester.getRect(
        find.byKey(const Key('board-seat-name-2')),
      );
      expect(
        record.overlaps(chip),
        isFalse,
        reason: s.why('record $record clear of the name chip $chip'),
      );
      for (int token = 0; token < 4; token++) {
        expect(
          _circleTouchesRect(_disc(tester, 2, token), record),
          isFalse,
          reason: s.why('record clear of seat 2 token $token'),
        );
      }
      for (final (int index, int face) in const <(int, int)>[(0, 6), (1, 3)]) {
        expect(
          find.descendant(
            of: find.byKey(seatRecordKey(2)),
            matching: find.byKey(trayDieKey(index)),
          ),
          findsOneWidget,
          reason: s.why('game-roll-tray-die-$index inside the record'),
        );
        expect(
          find.descendant(
            of: find.byKey(seatRecordKey(2)),
            matching: find.byKey(trayFaceKey(index, face)),
          ),
          findsOneWidget,
          reason: s.why('game-roll-tray-face-$index-$face inside the record'),
        );
        expect(
          find.byKey(trayDieKey(index)),
          findsOneWidget,
          reason: s.why('tile key $index is unique on screen'),
        );
      }
      for (final int other in const <int>[0, 1, 3]) {
        expect(
          find.byKey(seatRecordKey(other)),
          findsNothing,
          reason: s.why('no record for seat $other'),
        );
      }
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D4: my own queue stays under the board beside my die and no '
      'board-seat-record exists', (tester) async {
    final RollTrayDrive drive = await _mount(
      tester,
      turn: _awaitRoll(0),
      seats: _pair(mySeat: 0, mine: _oneOut, opponent: _yard),
    );
    final _Scn s = _Scn('D4 my record', tester, drive);
    try {
      await s.push(
        'rolled',
        _rolledData(0, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await s.push('turn', _turnData(0, queue: const <int>[6]));
      await s.push(
        'rolled',
        _rolledData(
          0,
          3,
          2,
          queue: const <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0]),
            faceLegal(3, const <int>[0]),
          ],
        ),
      );
      expect(
        find.byKey(rollTrayKey),
        findsOneWidget,
        reason: s.why('game-roll-tray is up under the board'),
      );
      expect(
        tester.getRect(find.byKey(rollTrayKey)).top,
        greaterThanOrEqualTo(boardSquare(tester).bottom - 1),
        reason: s.why('the tray is below the board'),
      );
      for (int seat = 0; seat < 4; seat++) {
        expect(
          find.byKey(seatRecordKey(seat)),
          findsNothing,
          reason: s.why('no board-seat-record-$seat on my own turn'),
        );
      }
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'D4: after seat 2\'s three sixes the dead record is seat 2\'s, on the '
    'board in its yard, while the turn is already mine; it leaves with the '
    'hold',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D4 dead hold', tester, drive);
      try {
        await s.push(
          'rolled',
          _rolledData(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
        );
        await s.push('turn', _turnData(2, queue: const <int>[6]));
        await s.push(
          'rolled',
          _rolledData(2, 6, 2, legal: const <int>[], queue: const <int>[6, 6]),
        );
        await s.push('turn', _turnData(2, queue: const <int>[6, 6]));
        await s.push(
          'rolled',
          _rolledData(2, 6, 3, legal: const <int>[], queue: const <int>[]),
        );
        await s.push('turn_passed', <String, Object?>{
          'seat': 2,
          'reason': 'three_sixes',
        });
        await s.push('turn', _turnData(0));
        expect(
          drive.controller.room!.turn!.seat,
          0,
          reason: s.why('fixture: it is my turn'),
        );
        expect(
          find.byKey(seatRecordKey(2)),
          findsOneWidget,
          reason: s.why('the dead record is drawn in seat 2\'s yard'),
        );
        expect(
          find.byKey(rollTrayKey),
          findsNothing,
          reason: s.why('nothing under the board for seat 2\'s record'),
        );
        for (final int index in const <int>[0, 1]) {
          expect(
            find.descendant(
              of: find.byKey(seatRecordKey(2)),
              matching: find.byKey(trayDeadKey(index)),
            ),
            findsOneWidget,
            reason: s.why('game-roll-tray-dead-$index inside the record'),
          );
        }
        await s.pump(const Duration(milliseconds: 1800));
        expect(
          find.byKey(seatRecordKey(2)),
          findsNothing,
          reason: s.why('the record leaves with the dead-faces hold'),
        );
        expect(
          find.byKey(rollTrayKey),
          findsNothing,
          reason: s.why('and no record appears under the board either'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // Semantics, taps and cues.
  // -------------------------------------------------------------------
  const Map<String, List<String>> words = <String, List<String>>{
    'en': <String>["Bob's die: 5", "Bob's die"],
    'ar': <String>['نرد Bob: 5', 'نرد Bob'],
  };
  for (final MapEntry<String, List<String>> entry in words.entries) {
    testWidgets(
      'Semantics ${entry.key}: a seat die reads "${entry.value[0]}" with a '
      'face and "${entry.value[1]}" without, one node, not a button',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final RollTrayDrive drive = await _mount(
          tester,
          locale: Locale(entry.key),
          turn: _awaitRoll(2),
          seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
        );
        final _Scn s = _Scn('Semantics ${entry.key}', tester, drive);
        try {
          void expectLabel(String label, String when) {
            expect(
              find.byKey(seatDieKey(2)),
              findsOneWidget,
              reason: s.why('$when: a seat die to read'),
            );
            final SemanticsNode node = tester.getSemantics(
              find.byKey(seatDieKey(2)),
            );
            expect(
              node.label,
              label,
              reason: s.why('$when: the label is "$label"'),
            );
            expect(
              node.flagsCollection.isButton,
              isFalse,
              reason: s.why('$when: not a button'),
            );
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isFalse,
              reason: s.why('$when: no tap action'),
            );
            expect(
              _semanticsLabels(tester).where((String l) => l.contains(label)),
              hasLength(1),
              reason: s.why('$when: exactly one node carries "$label"'),
            );
          }

          expectLabel(entry.value[1], 'no face yet');
          await s.push('rolled', _rolledData(2, 5, 1));
          await s.pump(_kThrowTotal);
          expectLabel(entry.value[0], 'face 5');
        } finally {
          handle.dispose();
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'a tap on the seat die centre with seat 2\'s yard empty sends nothing '
    'and plays no cue',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(
          mySeat: 0,
          mine: _oneOut,
          opponent: const <int>[0, 5, 10, 15],
        ),
      );
      final _Scn s = _Scn('tap on seat die', tester, drive);
      try {
        expect(
          find.byKey(seatDieKey(2)),
          findsOneWidget,
          reason: s.why('a seat die to tap'),
        );
        final Offset centre = tester.getCenter(find.byKey(seatDieKey(2)));
        final int sent = drive.transport.sentRaw.length;
        final List<FeedbackCue> cues = List<FeedbackCue>.of(
          drive.feedback.recorded,
        );
        await tester.tapAt(centre);
        await tester.pump();
        await tester.pump();
        expect(
          drive.transport.sentRaw.length,
          sent,
          reason: s.why('a tap at $centre sends nothing'),
        );
        expect(
          drive.feedback.recorded,
          cues,
          reason: s.why('a tap at $centre plays no cue'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D5: seat 2\'s rolled, throw and moved frames play no cue but the one '
    'dieLand when the throw lands (C-468 D4, order 469)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
      );
      final _Scn s = _Scn('D5 guard', tester, drive);
      try {
        final List<FeedbackCue> before = List<FeedbackCue>.of(
          drive.feedback.recorded,
        );
        // C-468 D4.1: another seat's die landing is heard, once.
        final List<FeedbackCue> after = <FeedbackCue>[...before, _dieLand];
        await s.push('rolled', _rolledData(2, 5, 1));
        expect(
          drive.feedback.recorded,
          before,
          reason: s.why('no cue on the rolled frame'),
        );
        Duration elapsed = Duration.zero;
        bool wasTumbling = true;
        while (elapsed < _kThrowTotal) {
          await tester.pump(_kFrame);
          elapsed += _kFrame;
          final bool tumbling = tester.any(
            find.byKey(opponentThrowTumblingKey(2)),
          );
          if (tumbling) {
            expect(
              drive.feedback.recorded,
              before,
              reason: s.why('no cue $elapsed into the tumble'),
            );
          } else if (wasTumbling) {
            expect(
              drive.feedback.recorded,
              anyOf(equals(before), equals(after)),
              reason: s.why('the landing frame, $elapsed into the throw'),
            );
          } else {
            expect(
              drive.feedback.recorded,
              after,
              reason: s.why('only dieLand $elapsed into the throw'),
            );
          }
          wasTumbling = tumbling;
        }
        await s.push('moved', _movedData(2, 0, 0, 5));
        expect(
          drive.feedback.recorded,
          after,
          reason: s.why('no further cue on the moved frame'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // Run 111 residue (C-465 D2), order 469.
  // -------------------------------------------------------------------
  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    testWidgets(
      'residue: a resync while seat $opp holds the turn on a 4 with no '
      'throw queued shows face 4 on its die, not the idle pose (seen from '
      '$me)',
      (tester) async {
        final List<Map<String, Object?>> seats = _pair(
          mySeat: me,
          mine: _oneOut,
          opponent: _oneOut,
        );
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: me,
          turn: _awaitRoll(opp),
          seats: seats,
        );
        final _Scn s = _Scn('residue resync me=$me opp=$opp', tester, drive);
        try {
          await s.push('rolled', _rolledData(opp, 5, 1));
          await s.pump(_kThrowTotal);
          _expectSeatDie(s, opp, 5, 'fixture: the 5 landed and is remembered');
          expect(
            find.byKey(opponentThrowKey(opp)),
            findsNothing,
            reason: s.why('fixture: no throw of seat $opp is up'),
          );
          await s.push(
            'room',
            roomData(
              seats: seats,
              turn: turnJson(
                seat: opp,
                phase: 'await_move',
                k: 1,
                value: 4,
                legal: const <int>[0],
                queue: const <int>[4],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(4, const <int>[0]),
                ],
              ),
            ),
          );
          expect(
            find.byKey(opponentThrowKey(opp)),
            findsNothing,
            reason: s.why('a snapshot starts no throw'),
          );
          _expectSeatDie(s, opp, 4, 'right after the resync');
          await s.pump(const Duration(milliseconds: 800));
          _expectSeatDie(s, opp, 4, 'after the resync has settled');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'residue: a resync that carries no value for the turn holder goes back '
    'to the idle pose, a resync that does carry one shows it',
    (tester) async {
      final List<Map<String, Object?>> seats = _pair(
        mySeat: 0,
        mine: _oneOut,
        opponent: _oneOut,
      );
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: seats,
      );
      final _Scn s = _Scn('residue resync twice', tester, drive);
      try {
        await s.push('rolled', _rolledData(2, 5, 1));
        await s.pump(_kThrowTotal);
        await s.push('room', roomData(seats: seats, turn: _awaitRoll(2, k: 4)));
        _expectSeatDie(s, 2, null, 'resync with no value: idle pose');
        await s.push('rolled', _rolledData(2, 2, 5));
        await s.pump(_kThrowTotal);
        _expectSeatDie(s, 2, 2, 'a new roll after the resync lands on 2');
        await s.push(
          'room',
          roomData(
            seats: seats,
            turn: turnJson(
              seat: 2,
              phase: 'await_move',
              k: 6,
              value: 6,
              legal: const <int>[0],
              queue: const <int>[6],
              legalByFace: <Map<String, Object?>>[
                faceLegal(6, const <int>[0]),
              ],
            ),
          ),
        );
        _expectSeatDie(s, 2, 6, 'second resync carries a 6');
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  for (final int bad in const <int>[0, 7, -3, 100]) {
    testWidgets(
      'residue: a rolled frame carrying face $bad for another seat throws '
      'nothing and leaves its die idle',
      (tester) async {
        final RollTrayDrive drive = await _mount(
          tester,
          turn: _awaitRoll(2),
          seats: _pair(mySeat: 0, mine: _oneOut, opponent: _oneOut),
        );
        final _Scn s = _Scn('residue rolled $bad', tester, drive);
        try {
          await s.push('rolled', _rolledData(2, bad, 1));
          await s.pump(_kThrowTotal);
          expect(
            tester.takeException(),
            isNull,
            reason: s.why('no exception for a rolled face of $bad'),
          );
          _expectSeatDie(s, 2, null, 'a face of $bad is not a face');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'residue: a snapshot carrying face $bad for another seat\'s turn '
      'throws nothing and leaves its die idle',
      (tester) async {
        final List<Map<String, Object?>> seats = _pair(
          mySeat: 0,
          mine: _oneOut,
          opponent: _oneOut,
        );
        final RollTrayDrive drive = await _mount(
          tester,
          turn: _awaitRoll(2),
          seats: seats,
        );
        final _Scn s = _Scn('residue snapshot $bad', tester, drive);
        try {
          await s.push(
            'room',
            roomData(
              seats: seats,
              turn: turnJson(
                seat: 2,
                phase: 'await_move',
                k: 1,
                value: bad,
                legal: const <int>[0],
                queue: <int>[bad],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(bad, const <int>[0]),
                ],
              ),
            ),
          );
          await s.pump(_kThrowTotal);
          expect(
            tester.takeException(),
            isNull,
            reason: s.why('no exception for a snapshot face of $bad'),
          );
          _expectSeatDie(s, 2, null, 'a snapshot face of $bad is not a face');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }
}
