// Screen proof for work/ludo/orders/586-watcher-dead-roll-countdown-warning.md,
// D1 to D5: a watcher is told why another seat's turn passed. Written from
// that contract alone, against a GameScreen over a real RoomController on
// FakeTransport (test/support/roll_tray_harness.dart); every state arrives as
// a decoded wire frame.
//
// The new strings do not exist as getters on a tree without the
// implementation, so the expected lines are built here from the arb text of
// D4 (the name goes where {name} stands), in English and in Arabic. A literal
// also catches a wrong word in the arb file that a getter-vs-getter
// comparison would pass.
//
// Keys named by the contract:
//   board-seat-die-dead-<seat>   the badge, a CustomPaint, D2
//   game-no-move-other-notice    the line under the die, D3
//
// Ambiguity, reported and not invented around: case (h) says the badge rect's
// right edge sits "within 2 px of the die's right edge". The badge the big die
// uses (deadBadgeRect) is centred on the die's top-right corner, so its right
// edge overhangs the die's right edge by half the badge. The cases below pin
// what both readings share: the badge is in the physical top-right quarter of
// the die, its right edge is no further than one badge width from the die's
// right edge, and the offset is the same in English and in Arabic (within
// 2 px). They do not pin the literal "right edge == die right edge".
//
// Order 589t (C-589 D1, D2) changes when the hold starts: a watcher dead end
// whose seat has a throw queued or in flight is armed at the landing of that
// throw (the seat die's face enters the board), not at the frames. The cases
// under "C-589" below drive that rule; the one C-586 case whose timing
// assertions encoded the old arm-at-frame rule (the first loop) is rewritten
// to measure from the landing, and every other C-586 case is unchanged. The
// landing is read off the screen: the frame on which the seat die shows the
// thrown face (board-seat-die-face-<seat>-<face>), which the seat die waits
// for until the throw leaves its tumble (C-465 D2).
//
// Every failure reason names the scenario and ends with the frames and pumps
// that led to it. The cases are deterministic, so the scenario is the whole
// reproduction; there is no seed.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/feedback.dart';

import 'support/roll_tray_harness.dart';

const Duration _kFrame = Duration(milliseconds: 16);

/// The hold, from the contract: `_noMoveHold`, 1500 ms, unchanged.
const int _kHoldMs = 1500;

const Key _otherNoticeKey = Key('game-no-move-other-notice');

Key _deadBadgeKey(int seat) => Key('board-seat-die-dead-$seat');

const List<int> _yard = <int>[-1, -1, -1, -1];

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

// --- D4, as literals --------------------------------------------------------

String _noMoveOtherEn(String name) => '$name: no move with this roll';
String _noMoveOtherAr(String name) => '$name: لا حركة بهذه الرمية';
String _threeSixesOtherEn(String name) =>
    '$name: three sixes in a row. Turn over.';
String _threeSixesOtherAr(String name) =>
    '$name: ثلاث ستّات متتالية. انتهى الدور.';

String _noMoveOther(Locale locale, String name) =>
    locale.languageCode == 'ar' ? _noMoveOtherAr(name) : _noMoveOtherEn(name);

String _threeSixesOther(Locale locale, String name) =>
    locale.languageCode == 'ar'
    ? _threeSixesOtherAr(name)
    : _threeSixesOtherEn(name);

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// --- scenario bookkeeping ----------------------------------------------------

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

  Future<void> pump(int ms) async {
    steps.add('pump ${ms}ms');
    await _pumpFrames(tester, Duration(milliseconds: ms));
  }

  /// Pumps 800 ms of frames and returns 800 if [done] holds then, else -1.
  /// A thrown die lands within 700 ms of its start (kThrowTumble) and the
  /// turn_passed behind the dead roll hurries it, so the landing is behind
  /// us at this point and the C-589 hold, armed at the landing, is still up.
  Future<int> landed(bool Function() done) async {
    await pump(800);
    if (done()) {
      return 800;
    }
    steps.add('condition did not hold 800ms after the dead end frames');
    return -1;
  }

  /// Pumps one 16 ms frame at a time. After each frame [until] is asked; the
  /// first frame on which it holds ends the wait and the elapsed time is
  /// returned. [each] sees every frame before that one, with the elapsed
  /// milliseconds. Returns -1 when [limitMs] passed without [until] holding.
  Future<int> frames({
    required int limitMs,
    bool Function()? until,
    void Function(int ms)? each,
  }) async {
    int elapsed = 0;
    while (elapsed < limitMs) {
      await tester.pump(_kFrame);
      elapsed += _kFrame.inMilliseconds;
      if (until != null && until()) {
        steps.add('frames ${elapsed}ms until the condition held');
        return elapsed;
      }
      each?.call(elapsed);
    }
    steps.add('frames ${elapsed}ms, the condition never held');
    return -1;
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

// --- fixtures ----------------------------------------------------------------

/// Two seats, 0 and 2 (the way a two-player room seats them). The other
/// seat is called Bob in both views, mine is Sam.
List<Map<String, Object?>> _pair({
  required int mySeat,
  List<int> mine = _yard,
  List<int> other = _yard,
}) {
  final int otherSeat = mySeat == 0 ? 2 : 0;
  final Map<int, Map<String, Object?>> bySeat = <int, Map<String, Object?>>{
    mySeat: seatJson(mySeat, name: 'Sam', tokens: mine),
    otherSeat: seatJson(otherSeat, name: 'Bob', tokens: other),
  };
  return <Map<String, Object?>>[bySeat[0]!, bySeat[2]!];
}

List<Map<String, Object?>> _quad({
  required int mySeat,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  Map<int, String> names = const <int, String>{},
}) => <Map<String, Object?>>[
  for (int seat = 0; seat < 4; seat++)
    seatJson(
      seat,
      name: seat == mySeat ? 'Sam' : (names[seat] ?? _names[seat]!),
      tokens: tokens[seat] ?? _yard,
    ),
];

Map<String, Object?> _awaitRoll(int seat, {int k = 0, List<int>? queue}) =>
    turnJson(seat: seat, phase: 'await_roll', k: k, queue: queue);

Map<String, Object?> _rolled(
  int seat,
  int value,
  int k, {
  List<int> legal = const <int>[],
  List<int> queue = const <int>[],
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': queue,
};

Map<String, Object?> _turnFrame(int seat, {List<int> queue = const <int>[]}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

/// Seat [seat] rolls [face] with no legal move and the turn passes to
/// [next], in the order of docs/PROTOCOL.md section 21.3 rule 4.
Future<void> _singleDeadRoll(
  _Scn s, {
  required int seat,
  required int next,
  int face = 3,
  int k = 1,
  String reason = 'no_legal_move',
}) async {
  await s.push('rolled', _rolled(seat, face, k));
  await s.push('turn_passed', <String, Object?>{
    'seat': seat,
    'reason': reason,
  });
  await s.push('turn', _turnFrame(next));
}

/// Seat [seat] has tokens [10,-1,-1,-1] and a queue [3,2,1] with the 2 as the
/// default face: it moves the 2 and the 3 and the 1 are dead (two faces, the
/// moved path).
Future<void> _movedPathTwoDead(
  _Scn s, {
  required int seat,
  required int next,
}) async {
  await s.push('turn', <String, Object?>{
    'seat': seat,
    'phase': 'await_move',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[3, 2, 1],
    'value': 2,
    'legal': <int>[0],
    'legal_by_face': <Map<String, Object?>>[
      faceLegal(2, const <int>[0]),
    ],
  });
  await s.push('moved', <String, Object?>{
    'seat': seat,
    'token': 0,
    'from': 10,
    'to': 12,
    'captured': <Object?>[],
    'extra_roll': false,
    'face': 2,
  });
  await s.push('turn_passed', <String, Object?>{
    'seat': seat,
    'reason': 'no_legal_move',
  });
  await s.push('turn', _turnFrame(next));
}

/// Same, with the queue [3,2]: one dead face (the 3) after the move.
Future<void> _movedPathOneDead(
  _Scn s, {
  required int seat,
  required int next,
}) async {
  await s.push('turn', <String, Object?>{
    'seat': seat,
    'phase': 'await_move',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[3, 2],
    'value': 2,
    'legal': <int>[0],
    'legal_by_face': <Map<String, Object?>>[
      faceLegal(2, const <int>[0]),
    ],
  });
  await s.push('moved', <String, Object?>{
    'seat': seat,
    'token': 0,
    'from': 10,
    'to': 12,
    'captured': <Object?>[],
    'extra_roll': false,
    'face': 2,
  });
  await s.push('turn_passed', <String, Object?>{
    'seat': seat,
    'reason': 'no_legal_move',
  });
  await s.push('turn', _turnFrame(next));
}

/// Seat [seat] throws 6, 6, 6: two queued sixes dead, then the third voids the
/// roll (docs/PROTOCOL.md section 21.3, the same frames test/seat_die_test.dart
/// D4 pushes).
Future<void> _threeSixes(_Scn s, {required int seat, required int next}) async {
  await s.push('rolled', _rolled(seat, 6, 1, queue: const <int>[6]));
  await s.push('turn', _turnFrame(seat, queue: const <int>[6]));
  await s.push('rolled', _rolled(seat, 6, 2, queue: const <int>[6, 6]));
  await s.push('turn', _turnFrame(seat, queue: const <int>[6, 6]));
  await s.push('rolled', _rolled(seat, 6, 3));
  await s.push('turn_passed', <String, Object?>{
    'seat': seat,
    'reason': 'three_sixes',
  });
  await s.push('turn', _turnFrame(next));
}

/// Seat [first] rolls [firstFace] with a legal move for its token 0 and moves
/// it, the turn reaches [second], who rolls a dead [deadFace]; [next] is the
/// seat after. All of it arrives with no time between the frames, so
/// [second]'s throw is queued behind [first]'s.
Future<void> _earlierThrowThenDead(
  _Scn s, {
  required int first,
  required int second,
  required int next,
  int firstFace = 4,
  int deadFace = 3,
}) async {
  await s.push('rolled', _rolled(first, firstFace, 1, legal: const <int>[0]));
  await s.push(
    'turn',
    turnJson(
      seat: first,
      phase: 'await_move',
      k: 1,
      value: firstFace,
      legal: const <int>[0],
      queue: <int>[firstFace],
      legalByFace: <Map<String, Object?>>[
        faceLegal(firstFace, const <int>[0]),
      ],
    ),
  );
  await s.push('moved', <String, Object?>{
    'seat': first,
    'token': 0,
    'from': 10,
    'to': 10 + firstFace,
    'captured': <Object?>[],
    'extra_roll': false,
    'face': firstFace,
  });
  await s.push('turn', _turnFrame(second));
  await _singleDeadRoll(s, seat: second, next: next, face: deadFace, k: 2);
}

bool _isDeadLine(String m) =>
    m.contains('no move with this roll') ||
    m.contains('three sixes in a row') ||
    m.contains('لا حركة بهذه الرمية') ||
    m.contains('ثلاث ستّات');

List<String> _deadLines(_Announcements said) => <String>[
  for (final String m in said.recorded)
    if (_isDeadLine(m)) m,
];

/// C-589 D1: while the dead roll's thrown die is in the air the watcher sees
/// no line, no badge on any seat and hears no dead-end announcement.
void _expectNothingYet(
  _Scn s,
  WidgetTester tester,
  _Announcements said,
  int ms,
) {
  expect(
    find.byKey(_otherNoticeKey),
    findsNothing,
    reason: s.why(
      'game-no-move-other-notice absent while the die is in the air '
      '(${ms}ms in)',
    ),
  );
  expect(
    _badgeSeats(tester),
    isEmpty,
    reason: s.why(
      'no board-seat-die-dead-* badge while the die is in the air '
      '(${ms}ms in)',
    ),
  );
  expect(
    _deadLines(said),
    isEmpty,
    reason: s.why(
      'no dead-end announcement while the die is in the air (${ms}ms in); '
      'announced ${said.recorded}',
    ),
  );
}

Future<RollTrayDrive> _mount(
  WidgetTester tester, {
  required Map<String, Object?> turn,
  required List<Map<String, Object?>> seats,
  int mySeat = 0,
  int players = 2,
  bool sendSeatAssigned = true,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: mySeat,
    players: players,
    sendSeatAssigned: sendSeatAssigned,
  );
  await mountGame(tester, drive, locale: locale, textScale: textScale);
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

// --- reading the screen ------------------------------------------------------

String? _otherNoticeText(WidgetTester tester) {
  final Finder f = find.byKey(_otherNoticeKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final Text text = tester.widget<Text>(f);
  return text.data ?? text.textSpan?.toPlainText();
}

bool _noticeUp(WidgetTester tester) => tester.any(find.byKey(_otherNoticeKey));

List<int> _badgeSeats(WidgetTester tester) => <int>[
  for (int seat = 0; seat < 4; seat++)
    if (tester.any(find.byKey(_deadBadgeKey(seat)))) seat,
];

/// The product of every Opacity, AnimatedOpacity and FadeTransition on the
/// key's element and above it, up to the LudoBoard.
double _opacityOf(WidgetTester tester, Key key) {
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

class _Announcements {
  final List<String> recorded = <String>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          recorded.add(data['message'] as String);
        }
        return null;
      },
    );
  }

  void remove(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    );
  }
}

void main() {
  // ===========================================================================
  // (a), (b): two seats, the other seat's single dead roll, both directions.
  // ===========================================================================
  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;
    for (final int mySeat in const <int>[0, 2]) {
      final int rolling = mySeat == 0 ? 2 : 0;
      testWidgets(
        'C-586 D1/D2/D3 ($lang): I am seat $mySeat, seat $rolling rolls one '
        'face with no legal move: the badge and the line show for the hold, '
        'then both go',
        (tester) async {
          final RollTrayDrive drive = await _mount(
            tester,
            mySeat: mySeat,
            locale: locale,
            turn: _awaitRoll(rolling),
            seats: _pair(mySeat: mySeat),
          );
          final _Scn s = _Scn(
            'two seats, me=$mySeat, seat $rolling dead roll of 3, $lang',
            tester,
            drive,
          );
          try {
            await _singleDeadRoll(s, seat: rolling, next: mySeat);
            // C-589 D1: the hold is armed when the dead roll's thrown die
            // lands (the seat die shows its 3), so the clock below starts
            // there and not at the frames.
            final int waited = await s.frames(
              limitMs: 1500,
              until: () => tester.any(find.byKey(seatDieFaceKey(rolling, 3))),
            );
            expect(
              waited,
              isNot(-1),
              reason: s.why('seat $rolling\'s die lands on its 3'),
            );
            expect(
              _noticeUp(tester),
              isTrue,
              reason: s.why(
                'game-no-move-other-notice appears for seat $rolling on the '
                'frame its die lands (${waited}ms after the push)',
              ),
            );
            expect(
              _otherNoticeText(tester),
              _noMoveOther(locale, 'Bob'),
              reason: s.why(
                'the line reads "${_noMoveOther(locale, 'Bob')}" '
                '(gameNoMoveOther with the seat display name)',
              ),
            );
            expect(
              find.byKey(_deadBadgeKey(rolling)),
              findsOneWidget,
              reason: s.why(
                'board-seat-die-dead-$rolling is on seat '
                '$rolling\'s die',
              ),
            );
            expect(
              tester.widget(find.byKey(_deadBadgeKey(rolling))),
              isA<CustomPaint>(),
              reason: s.why('the badge is a CustomPaint (D2)'),
            );
            expect(_badgeSeats(tester), <int>[
              rolling,
            ], reason: s.why('the badge is on seat $rolling only'));
            expect(
              find.byKey(noMoveNoticeKey),
              findsNothing,
              reason: s.why(
                'my own game-no-move-notice is not used for '
                'another seat',
              ),
            );
            expect(
              _opacityOf(tester, seatDieKey(rolling)),
              closeTo(1.0, 0.01),
              reason: s.why(
                'the dead die paints at full opacity, not the '
                '0.45 of an idle die',
              ),
            );
            expect(
              find.byKey(seatDieFaceKey(rolling, 3)),
              findsOneWidget,
              reason: s.why('the dead face (a 3) is the one the die shows'),
            );
            await s.pump(1400);
            expect(
              find.byKey(_otherNoticeKey),
              findsOneWidget,
              reason: s.why(
                'the line is still up 1400 ms after the landing, inside the '
                '$_kHoldMs ms hold',
              ),
            );
            expect(
              _badgeSeats(tester),
              <int>[rolling],
              reason: s.why('the badge is still up 1400 ms after the landing'),
            );
            await s.pump(200);
            expect(
              find.byKey(_otherNoticeKey),
              findsNothing,
              reason: s.why(
                'the line is gone 1600 ms after the landing, after the hold',
              ),
            );
            expect(
              _badgeSeats(tester),
              isEmpty,
              reason: s.why(
                'the badge is gone 1600 ms after the landing, after the hold',
              ),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  }

  // ===========================================================================
  // (c): four seats, the badge is on the rolling seat's die only.
  // ===========================================================================
  testWidgets(
    'C-586 D2 (c): four seats, I am seat 1, seat 3 dead roll: the badge is '
    'on seat 3 only, the line names Dan',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn(
        'four seats, me=1, seat 3 dead roll of 3',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 3, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _otherNoticeText(tester),
          _noMoveOtherEn('Dan'),
          reason: s.why('the line names seat 3, "Dan"'),
        );
        expect(
          find.byKey(_deadBadgeKey(3)),
          findsOneWidget,
          reason: s.why('board-seat-die-dead-3 present'),
        );
        for (final int seat in const <int>[0, 1, 2]) {
          expect(
            find.byKey(_deadBadgeKey(seat)),
            findsNothing,
            reason: s.why('board-seat-die-dead-$seat absent'),
          );
        }
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // ===========================================================================
  // (d): three sixes.
  // ===========================================================================
  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;
    testWidgets('C-586 D3 (d) ($lang): another seat\'s three sixes read the '
        'three-sixes line', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        locale: locale,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 three sixes, $lang',
        tester,
        drive,
      );
      try {
        await _threeSixes(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _otherNoticeText(tester),
          _threeSixesOther(locale, 'Bob'),
          reason: s.why(
            'the line reads "${_threeSixesOther(locale, 'Bob')}" '
            '(gameThreeSixesOther)',
          ),
        );
        expect(
          find.byKey(noMoveNoticeKey),
          findsNothing,
          reason: s.why('not my own notice'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });
  }

  // ===========================================================================
  // (e): my own dead roll, today's behaviour.
  // ===========================================================================
  testWidgets(
    'C-586 D1/D3/D5 (e): my own dead roll keeps game-no-move-notice, my big '
    'die mark and the no_move cue; the other-seat line is not used',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[-1, 55, 57, 57]),
        turn: turnJson(
          seat: 0,
          phase: 'await_roll',
          k: 0,
          queue: const <int>[],
        ),
      );
      await mountGame(tester, drive);
      final _Scn s = _Scn(
        'my own dead roll, tokens [-1,55,57,57], a 4',
        tester,
        drive,
      );
      try {
        await pushMyNoMoveRoll(tester, drive, face: 4);
        s.steps.add('pushMyNoMoveRoll face 4');
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason: s.why('game-no-move-notice is shown'),
        );
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('game-no-move-other-notice is absent for my own seat'),
        );
        expect(
          find.byKey(noMoveMarkKey),
          findsOneWidget,
          reason: s.why('my big die carries game-die-no-move-mark'),
        );
        expect(
          cueCount(drive.feedback, FeedbackCue.noMove),
          1,
          reason: s.why(
            'exactly one no_move cue for my own dead end; '
            'recorded ${drive.feedback.recorded}',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // ===========================================================================
  // Controls: the frames each case pushes are accepted by today's screen and
  // reach the state the case describes (the turn moved on, the die shows its
  // roll). These hold with or without the implementation, so a red case above
  // is red for the missing feature and not for a broken fixture.
  // ===========================================================================
  group('C-586 fixture controls (green without the implementation)', () {
    testWidgets('single dead roll, two seats, me=2: the turn moves on to me '
        'and seat 0 die shows the 3', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 2,
        turn: _awaitRoll(0),
        seats: _pair(mySeat: 2),
      );
      final _Scn s = _Scn(
        'control: me=2, seat 0 dead roll of 3',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 0, next: 2);
        await s.pump(800);
        expect(
          drive.controller.room!.turn!.seat,
          2,
          reason: s.why('the turn is mine after seat 0 passed'),
        );
        expect(
          find.byKey(seatDieFaceKey(0, 3)),
          findsOneWidget,
          reason: s.why('seat 0 die shows its 3'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('moved path with queue [3,2,1]: seat 2 token moved, the '
        'turn is mine, the yard record of seat 2 is drawn', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, other: const <int>[10, -1, -1, -1]),
      );
      final _Scn s = _Scn('control: moved path two dead faces', tester, drive);
      try {
        await _movedPathTwoDead(s, seat: 2, next: 0);
        await s.pump(48);
        expect(drive.controller.room!.turn!.seat, 0, reason: s.why('my turn'));
        expect(
          drive.controller.room!.seats
              .firstWhere((seat) => seat.seat == 2)
              .tokens[0],
          12,
          reason: s.why('seat 2 token 0 moved 10 to 12'),
        );
        expect(
          find.byKey(seatRecordKey(2)),
          findsOneWidget,
          reason: s.why('the dead record of seat 2 is drawn'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('three sixes: the turn is mine and the record of seat 2 is '
        'drawn', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('control: three sixes', tester, drive);
      try {
        await _threeSixes(s, seat: 2, next: 0);
        await s.pump(48);
        expect(drive.controller.room!.turn!.seat, 0, reason: s.why('my turn'));
        expect(
          find.byKey(seatRecordKey(2)),
          findsOneWidget,
          reason: s.why('the dead record of seat 2 is drawn'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('four seats: seat 3 dead roll records only the existing '
        'dieLand sound and no no_move cue', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn(
        'control: four seats, seat 3 dead, cues',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 3, next: 0);
        await s.pump(1800);
        expect(drive.controller.room!.turn!.seat, 0, reason: s.why('seat 0'));
        expect(
          cueCount(drive.feedback, FeedbackCue.noMove),
          0,
          reason: s.why('no no_move cue; recorded ${drive.feedback.recorded}'),
        );
        expect(
          drive.feedback.recorded.where(
            (FeedbackCue c) => c != FeedbackCue.dieLand,
          ),
          isEmpty,
          reason: s.why('only dieLand; recorded ${drive.feedback.recorded}'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('a spectator mounts and takes the frames', (tester) async {
      final RollTrayDrive spec = await _mount(
        tester,
        sendSeatAssigned: false,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('control: spectator', tester, spec);
      try {
        expect(spec.controller.seat, isNull, reason: s.why('no seat'));
        await _singleDeadRoll(s, seat: 2, next: 0);
        await s.pump(800);
        expect(spec.controller.room!.turn!.seat, 0, reason: s.why('seat 0'));
      } finally {
        await releaseGame(tester, spec);
      }
    });
  });

  // ===========================================================================
  // (f): no haptic, no sound for another seat's dead end.
  // ===========================================================================
  testWidgets(
    'C-586 D5 (f): another seat\'s dead end records no no_move cue and no '
    'cue beyond the die landing sound that exists today',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn(
        'four seats, me=1, seat 3 dead roll, cues',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 3, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(
          waited,
          isNot(-1),
          reason: s.why(
            'fixture: the line appears, so the dead end was '
            'resolved before the cues are read',
          ),
        );
        await s.pump(_kHoldMs + 300);
        expect(
          cueCount(drive.feedback, FeedbackCue.noMove),
          0,
          reason: s.why(
            'no no_move cue for seat 3\'s dead end; recorded '
            '${drive.feedback.recorded}',
          ),
        );
        final Set<FeedbackCue> extra = drive.feedback.recorded
            .where((FeedbackCue c) => c != FeedbackCue.dieLand)
            .toSet();
        expect(
          extra,
          isEmpty,
          reason: s.why(
            'nothing but the existing sound-only dieLand is '
            'played for another seat\'s dead roll; recorded '
            '${drive.feedback.recorded}',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // ===========================================================================
  // (g): TalkBack, once.
  // ===========================================================================
  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;
    for (final String reason in const <String>[
      'no_legal_move',
      'three_sixes',
    ]) {
      testWidgets(
        'C-586 D5 (g) ($lang): $reason is announced once, equal to the line',
        (tester) async {
          final _Announcements said = _Announcements();
          said.install(tester);
          addTearDown(() => said.remove(tester));
          final RollTrayDrive drive = await _mount(
            tester,
            locale: locale,
            turn: _awaitRoll(2),
            seats: _pair(mySeat: 0),
          );
          final _Scn s = _Scn(
            'two seats, me=0, seat 2 $reason, announce, $lang',
            tester,
            drive,
          );
          try {
            said.recorded.clear();
            if (reason == 'three_sixes') {
              await _threeSixes(s, seat: 2, next: 0);
            } else {
              await _singleDeadRoll(s, seat: 2, next: 0);
            }
            final int waited = await s.landed(() => _noticeUp(tester));
            expect(waited, isNot(-1), reason: s.why('the line appears'));
            await s.pump(_kHoldMs + 300);
            final String line = reason == 'three_sixes'
                ? _threeSixesOther(locale, 'Bob')
                : _noMoveOther(locale, 'Bob');
            final List<String> matching = <String>[
              for (final String m in said.recorded)
                if (m == line) m,
            ];
            expect(
              matching,
              <String>[line],
              reason: s.why(
                'exactly one announcement "$line"; all '
                'announcements: ${said.recorded}',
              ),
            );
            final List<String> otherLines = <String>[
              for (final String m in said.recorded)
                if (m != line &&
                    (m.contains('no move with this roll') ||
                        m.contains('three sixes in a row') ||
                        m.contains('لا حركة بهذه الرمية') ||
                        m.contains('ثلاث ستّات')))
                  m,
            ];
            expect(
              otherLines,
              isEmpty,
              reason: s.why(
                'no second dead-end announcement of another '
                'wording; all announcements: ${said.recorded}',
              ),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  }

  // ===========================================================================
  // (h): Arabic, and the badge corner.
  // ===========================================================================
  testWidgets(
    'C-586 D2 (h): the badge sits at the die\'s physical top-right in English '
    'and in Arabic, and in a view rotated by my seat',
    (tester) async {
      final Map<String, double> offsetByLocale = <String, double>{};
      for (final Locale locale in _locales) {
        for (final int mySeat in const <int>[0, 2]) {
          final int rolling = mySeat == 0 ? 2 : 0;
          final RollTrayDrive drive = await _mount(
            tester,
            mySeat: mySeat,
            locale: locale,
            turn: _awaitRoll(rolling),
            seats: _pair(mySeat: mySeat),
          );
          final _Scn s = _Scn(
            'badge corner, me=$mySeat, seat $rolling dead, '
            '${locale.languageCode}',
            tester,
            drive,
          );
          try {
            await _singleDeadRoll(s, seat: rolling, next: mySeat);
            final int waited = await s.landed(
              () => tester.any(find.byKey(_deadBadgeKey(rolling))),
            );
            expect(waited, isNot(-1), reason: s.why('the badge appears'));
            expect(
              _otherNoticeText(tester),
              _noMoveOther(locale, 'Bob'),
              reason: s.why('the line is the ${locale.languageCode} text'),
            );
            final Rect die = tester.getRect(find.byKey(seatDieKey(rolling)));
            final Rect badge = tester.getRect(
              find.byKey(_deadBadgeKey(rolling)),
            );
            expect(
              badge.center.dx,
              greaterThanOrEqualTo(die.center.dx),
              reason: s.why(
                'badge centre is in the right half of the die '
                '(physical, not mirrored); die $die badge $badge',
              ),
            );
            expect(
              badge.center.dy,
              lessThanOrEqualTo(die.center.dy),
              reason: s.why(
                'badge centre is in the top half of the die; '
                'die $die badge $badge',
              ),
            );
            expect(
              (badge.right - die.right).abs(),
              lessThanOrEqualTo(badge.width + 2),
              reason: s.why(
                'badge right edge is within one badge width of '
                'the die right edge; die $die badge $badge',
              ),
            );
            offsetByLocale['${locale.languageCode}/$mySeat'] =
                badge.right - die.right;
          } finally {
            await releaseGame(tester, drive);
          }
        }
      }
      for (final int mySeat in const <int>[0, 2]) {
        final double en = offsetByLocale['en/$mySeat']!;
        final double ar = offsetByLocale['ar/$mySeat']!;
        expect(
          (en - ar).abs(),
          lessThanOrEqualTo(2),
          reason:
              'badge-vs-die right edge offset differs between locales '
              'for me=$mySeat: en $en, ar $ar (the badge must not mirror)',
        );
      }
    },
  );

  // ===========================================================================
  // (i): two or more faces draw no badge, the line still shows.
  // ===========================================================================
  testWidgets(
    'C-586 D2 (i): a moved-path dead end with two faces shows the line and '
    'no board-seat-die-dead badge',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, other: const <int>[10, -1, -1, -1]),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 moved path, faces 3 and 1',
        tester,
        drive,
      );
      try {
        await _movedPathTwoDead(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _otherNoticeText(tester),
          _noMoveOtherEn('Bob'),
          reason: s.why('the line is gameNoMoveOther("Bob")'),
        );
        expect(
          _badgeSeats(tester),
          isEmpty,
          reason: s.why('no board-seat-die-dead-* badge with two dead faces'),
        );
        expect(
          find.byKey(seatRecordKey(2)),
          findsOneWidget,
          reason: s.why(
            'the yard record of seat 2 still draws the dead '
            'tiles, as today',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-586 D2 (i): three sixes (two dead faces in the record) shows the line '
    'and no board-seat-die-dead badge',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 three sixes, badge',
        tester,
        drive,
      );
      try {
        await _threeSixes(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _badgeSeats(tester),
          isEmpty,
          reason: s.why('no board-seat-die-dead-* badge with two dead faces'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-586 D1/D2: a moved-path dead end with ONE dead face arms the badge '
    'too (any path, any count of faces is a trigger; one face draws it)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, other: const <int>[10, -1, -1, -1]),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 moved path, one dead face',
        tester,
        drive,
      );
      try {
        await _movedPathOneDead(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _otherNoticeText(tester),
          _noMoveOtherEn('Bob'),
          reason: s.why('the line is gameNoMoveOther("Bob")'),
        );
        expect(_badgeSeats(tester), <int>[
          2,
        ], reason: s.why('exactly one dead face: the badge is on seat 2'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // ===========================================================================
  // D1: spectator, replacement, priority.
  // ===========================================================================
  testWidgets(
    'C-586 D1/D3: a device with no seat sees the line for any seat\'s dead '
    'roll (no seat die is drawn for a spectator today, so no badge is '
    'asserted)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        sendSeatAssigned: false,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'spectator (no seat), seat 2 dead roll of 3',
        tester,
        drive,
      );
      try {
        expect(
          drive.controller.seat,
          isNull,
          reason: s.why('fixture: this device has no seat'),
        );
        await _singleDeadRoll(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        expect(
          _otherNoticeText(tester),
          _noMoveOtherEn('Bob'),
          reason: s.why('the line is gameNoMoveOther("Bob")'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-586 D1: a newer dead end replaces the armed one (line and badge move '
    'to the new seat)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn(
        'four seats, me=1, seat 3 then seat 0 dead',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 3, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('seat 3\'s line appears'));
        await s.pump(300);
        await _singleDeadRoll(s, seat: 0, next: 1, face: 4, k: 2);
        await s.pump(800);
        expect(
          _otherNoticeText(tester),
          _noMoveOtherEn('Ann'),
          reason: s.why('the line now names seat 0, "Ann", not "Dan"'),
        );
        expect(_badgeSeats(tester), <int>[
          0,
        ], reason: s.why('the badge moved to seat 0 only'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-586 D1/D3: my own dead end inside another seat\'s hold takes the slot '
    '(own notice shown, other-seat line gone)',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead then my dead inside the hold',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('seat 2\'s line appears'));
        await s.pump(200);
        await _singleDeadRoll(s, seat: 0, next: 2, face: 4, k: 2);
        await s.pump(48);
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason: s.why('my own notice takes the slot'),
        );
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('the other-seat line is gone while mine is up'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // ===========================================================================
  // D3: the line's shape and the slot.
  // ===========================================================================
  testWidgets(
    'C-586 D3: the line is one line, maxLines 1, ellipsis, and its seat die '
    'badge hold ends with it',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead, line shape',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 2, next: 0);
        final int waited = await s.landed(() => _noticeUp(tester));
        expect(waited, isNot(-1), reason: s.why('the line appears'));
        final Text text = tester.widget<Text>(find.byKey(_otherNoticeKey));
        expect(text.maxLines, 1, reason: s.why('maxLines: 1'));
        expect(
          text.overflow,
          TextOverflow.ellipsis,
          reason: s.why('overflow: ellipsis'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  group('C-586 D3 the slot never resizes (360 x 800, text scale 2.0)', () {
    const double scale = 2.0;

    /// The height of the slot while the own notice is up, on a fresh mount.
    Future<double> ownSlotHeight(WidgetTester tester, Locale locale) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: twoSeats(mine: const <int>[-1, 55, 57, 57]),
        turn: turnJson(
          seat: 0,
          phase: 'await_roll',
          k: 0,
          queue: const <int>[],
        ),
      );
      await mountGame(tester, drive, locale: locale, textScale: scale);
      try {
        await pushMyNoMoveRoll(tester, drive, face: 4);
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason:
              'fixture: own notice up to measure the slot (${locale.languageCode})',
        );
        return noMoveNoticeSlotHeight(tester);
      } finally {
        await releaseGame(tester, drive);
      }
    }

    for (final Locale locale in _locales) {
      for (final String reason in const <String>[
        'no_legal_move',
        'three_sixes',
      ]) {
        for (final String longName in const <String>[
          '',
          'Bartholomew-Maximilian Fitzgerald',
        ]) {
          testWidgets('${locale.languageCode}, $reason, '
              '${longName.isEmpty ? 'short name' : 'long name'}: the slot is as '
              'tall as with my own notice, the board does not move, nothing '
              'overflows', (tester) async {
            _phone(tester);
            final double ownHeight = await ownSlotHeight(tester, locale);
            final String opponent = longName.isEmpty ? 'Bob' : longName;
            final RollTrayDrive drive = await connectPlaying(
              tester,
              mySeat: 0,
              turn: _awaitRoll(2),
              seats: <Map<String, Object?>>[
                seatJson(0, name: 'Sam'),
                seatJson(2, name: opponent),
              ],
            );
            await mountGame(tester, drive, locale: locale, textScale: scale);
            final _Scn s = _Scn(
              '360x800 scale 2.0, ${locale.languageCode}, $reason, '
              'opponent "$opponent"',
              tester,
              drive,
            );
            try {
              final Rect boardBefore = tester.getRect(find.byKey(boardKey));
              if (reason == 'three_sixes') {
                await _threeSixes(s, seat: 2, next: 0);
              } else {
                await _singleDeadRoll(s, seat: 2, next: 0);
              }
              final int waited = await s.landed(() => _noticeUp(tester));
              expect(waited, isNot(-1), reason: s.why('the line appears'));
              final Finder slot = find
                  .ancestor(
                    of: find.byKey(_otherNoticeKey),
                    matching: find.byType(Stack),
                  )
                  .first;
              expect(
                tester.getSize(slot).height,
                ownHeight,
                reason: s.why(
                  'the slot is as tall with this line as with '
                  'game-no-move-notice ($ownHeight); the new strings must '
                  'be among the slot\'s measured placeholders',
                ),
              );
              expect(
                tester.getRect(find.byKey(boardKey)),
                boardBefore,
                reason: s.why(
                  'game-screen-board did not move when the '
                  'line arrived',
                ),
              );
              expect(
                tester.takeException(),
                isNull,
                reason: s.why('no layout or overflow exception'),
              );
            } finally {
              await releaseGame(tester, drive);
            }
          });
        }
      }
    }
  });

  // ===========================================================================
  // C-589 (order 589t). D1: the watcher dead end waits for the dead roll's
  // thrown die to land. D2: a pending one is dropped when it is superseded.
  // ===========================================================================
  group('C-589 fixture controls (green without the implementation)', () {
    testWidgets('after the frames of a dead roll the thrown die is still in '
        'the air and the seat die is not drawn', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('control: dead roll in the air', tester, drive);
      try {
        await _singleDeadRoll(s, seat: 2, next: 0);
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('seat 2\'s thrown die tumbles right after the push'),
        );
        expect(
          find.byKey(seatDieFaceKey(2, 3)),
          findsNothing,
          reason: s.why('the seat die holds back until the throw lands'),
        );
        final int landedMs = await s.frames(
          limitMs: 1500,
          until: () => tester.any(find.byKey(seatDieFaceKey(2, 3))),
        );
        expect(
          landedMs,
          allOf(greaterThan(0), lessThanOrEqualTo(800)),
          reason: s.why('the die lands within the 700 ms tumble'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('an earlier throw of another seat holds the dead roll\'s '
        'throw in the queue', (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(
          mySeat: 1,
          tokens: const <int, List<int>>{
            3: <int>[10, -1, -1, -1],
          },
        ),
      );
      final _Scn s = _Scn('control: queued throw', tester, drive);
      try {
        await _earlierThrowThenDead(s, first: 3, second: 0, next: 1);
        expect(
          find.byKey(opponentThrowKey(3)),
          findsOneWidget,
          reason: s.why('seat 3\'s earlier throw is the one in flight'),
        );
        expect(
          find.byKey(opponentThrowKey(0)),
          findsNothing,
          reason: s.why('seat 0\'s throw waits in the queue behind it'),
        );
        final int landedMs = await s.frames(
          limitMs: 3000,
          until: () => tester.any(find.byKey(seatDieFaceKey(0, 3))),
        );
        expect(
          landedMs,
          isNot(-1),
          reason: s.why('seat 0\'s die lands once its turn in the queue comes'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });
  });

  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;
    for (final int mySeat in const <int>[0, 2]) {
      final int rolling = mySeat == 0 ? 2 : 0;
      testWidgets(
        'C-589 D1 (a) ($lang): I am seat $mySeat, seat $rolling dead roll '
        'still in the air: no line, no badge, no announcement while it '
        'tumbles; from the landing line, badge and one announcement for the '
        'full hold',
        (tester) async {
          final _Announcements said = _Announcements();
          said.install(tester);
          addTearDown(() => said.remove(tester));
          final RollTrayDrive drive = await _mount(
            tester,
            mySeat: mySeat,
            locale: locale,
            turn: _awaitRoll(rolling),
            seats: _pair(mySeat: mySeat),
          );
          final _Scn s = _Scn(
            'two seats, me=$mySeat, seat $rolling dead roll of 3 in the air, '
            '$lang',
            tester,
            drive,
          );
          final String line = _noMoveOther(locale, 'Bob');
          try {
            said.recorded.clear();
            await _singleDeadRoll(s, seat: rolling, next: mySeat);
            expect(
              find.byKey(opponentThrowTumblingKey(rolling)),
              findsOneWidget,
              reason: s.why('fixture: the dead roll\'s die is in the air'),
            );
            _expectNothingYet(s, tester, said, 0);
            final int landedMs = await s.frames(
              limitMs: 1500,
              until: () => tester.any(find.byKey(seatDieFaceKey(rolling, 3))),
              each: (int ms) => _expectNothingYet(s, tester, said, ms),
            );
            expect(
              landedMs,
              isNot(-1),
              reason: s.why('seat $rolling\'s die lands on its 3'),
            );
            expect(
              _otherNoticeText(tester),
              line,
              reason: s.why(
                'on the frame the die lands (${landedMs}ms after the push) '
                'the line reads "$line"',
              ),
            );
            expect(
              _badgeSeats(tester),
              <int>[rolling],
              reason: s.why(
                'on the frame the die lands the badge is on seat $rolling '
                'only',
              ),
            );
            await s.pump(16);
            expect(
              _deadLines(said),
              <String>[line],
              reason: s.why(
                'exactly one announcement "$line" at the landing; all '
                'announcements: ${said.recorded}',
              ),
            );
            await s.pump(1400 - 16);
            expect(
              _otherNoticeText(tester),
              line,
              reason: s.why(
                'the line is still up 1400 ms after the landing (${landedMs}ms '
                'after the push)',
              ),
            );
            expect(
              _badgeSeats(tester),
              <int>[rolling],
              reason: s.why('the badge is still up 1400 ms after the landing'),
            );
            await s.pump(200);
            expect(
              find.byKey(_otherNoticeKey),
              findsNothing,
              reason: s.why('the line is gone 1600 ms after the landing'),
            );
            expect(
              _badgeSeats(tester),
              isEmpty,
              reason: s.why('the badge is gone 1600 ms after the landing'),
            );
            expect(
              _deadLines(said),
              <String>[line],
              reason: s.why(
                'still exactly one announcement after the hold; all '
                'announcements: ${said.recorded}',
              ),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  }

  testWidgets(
    'C-589 D1 (a) three sixes: no line, badge or announcement before the '
    'first of seat 2\'s throws has landed; the line comes with one '
    'announcement and no badge',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn('two seats, me=0, seat 2 three sixes', tester, drive);
      final String line = _threeSixesOtherEn('Bob');
      try {
        said.recorded.clear();
        await _threeSixes(s, seat: 2, next: 0);
        expect(
          find.byKey(opponentThrowKey(2)),
          findsOneWidget,
          reason: s.why('fixture: a throw of seat 2 is up, more are queued'),
        );
        _expectNothingYet(s, tester, said, 0);
        final int firstLandingMs = await s.frames(
          limitMs: 1500,
          until: () => tester.any(find.byKey(seatDieFaceKey(2, 6))),
          each: (int ms) => _expectNothingYet(s, tester, said, ms),
        );
        expect(
          firstLandingMs,
          isNot(-1),
          reason: s.why('the first six lands on seat 2\'s die'),
        );
        final int lineMs = await s.frames(
          limitMs: 3000,
          until: () => tester.any(find.byKey(_otherNoticeKey)),
        );
        expect(
          lineMs,
          isNot(-1),
          reason: s.why(
            'the three-sixes line appears once the sixes have landed',
          ),
        );
        expect(
          _otherNoticeText(tester),
          line,
          reason: s.why('the line reads "$line"'),
        );
        expect(
          _badgeSeats(tester),
          isEmpty,
          reason: s.why('no badge with two dead faces'),
        );
        await s.pump(1700);
        expect(_deadLines(said), <String>[
          line,
        ], reason: s.why('one announcement "$line"; all: ${said.recorded}'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // (b): the dead roll's throw waits in the queue behind an earlier throw.
  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;
    testWidgets(
      'C-589 D1 (b) ($lang): seat 0 dead roll queued behind seat 3\'s earlier '
      'throw: nothing while it waits and tumbles, everything from its '
      'landing, held 1500 ms from there',
      (tester) async {
        final _Announcements said = _Announcements();
        said.install(tester);
        addTearDown(() => said.remove(tester));
        final RollTrayDrive drive = await _mount(
          tester,
          mySeat: 1,
          players: 4,
          locale: locale,
          turn: _awaitRoll(3),
          seats: _quad(
            mySeat: 1,
            tokens: const <int, List<int>>{
              3: <int>[10, -1, -1, -1],
            },
          ),
        );
        final _Scn s = _Scn(
          'four seats, me=1, seat 3 moves a 4, seat 0 dead roll of 3 queued '
          'behind it, $lang',
          tester,
          drive,
        );
        final String line = _noMoveOther(locale, 'Ann');
        try {
          said.recorded.clear();
          await _earlierThrowThenDead(s, first: 3, second: 0, next: 1);
          expect(
            find.byKey(opponentThrowKey(0)),
            findsNothing,
            reason: s.why('fixture: seat 0\'s throw is still queued'),
          );
          _expectNothingYet(s, tester, said, 0);
          final int landedMs = await s.frames(
            limitMs: 3000,
            until: () => tester.any(find.byKey(seatDieFaceKey(0, 3))),
            each: (int ms) => _expectNothingYet(s, tester, said, ms),
          );
          expect(
            landedMs,
            isNot(-1),
            reason: s.why('seat 0\'s die lands on its 3'),
          );
          expect(
            _otherNoticeText(tester),
            line,
            reason: s.why(
              'on the frame seat 0\'s die lands (${landedMs}ms after the '
              'push) the line reads "$line"',
            ),
          );
          expect(_badgeSeats(tester), <int>[
            0,
          ], reason: s.why('the badge is on seat 0 only at the landing'));
          await s.pump(16);
          expect(
            _deadLines(said),
            <String>[line],
            reason: s.why(
              'exactly one announcement "$line" at the landing; all '
              'announcements: ${said.recorded}',
            ),
          );
          await s.pump(1400 - 16);
          expect(
            _otherNoticeText(tester),
            line,
            reason: s.why('the line is still up 1400 ms after the landing'),
          );
          expect(_badgeSeats(tester), <int>[
            0,
          ], reason: s.why('the badge is still up 1400 ms after the landing'));
          await s.pump(200);
          expect(
            find.byKey(_otherNoticeKey),
            findsNothing,
            reason: s.why('the line is gone 1600 ms after the landing'),
          );
          expect(
            _badgeSeats(tester),
            isEmpty,
            reason: s.why('the badge is gone 1600 ms after the landing'),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  // Reduced motion: a throw lands on its first frame (no tumble phase), so a
  // pending dead end that waited for a tumble to end would never arm.
  testWidgets(
    'C-589 D1 (reduced motion): with animations disabled a watcher dead end '
    'still shows its line and badge, announces once and holds 1500 ms',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: _pair(mySeat: 0),
        turn: _awaitRoll(2),
      );
      await mountGame(tester, drive, disableAnimations: true);
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead roll of 3, disableAnimations',
        tester,
        drive,
      );
      final String line = _noMoveOtherEn('Bob');
      try {
        said.recorded.clear();
        await _singleDeadRoll(s, seat: 2, next: 0);
        final int shownMs = await s.frames(
          limitMs: 1000,
          until: () => tester.any(find.byKey(_otherNoticeKey)),
        );
        expect(
          shownMs,
          isNot(-1),
          reason: s.why('the line must appear under reduced motion'),
        );
        expect(
          _otherNoticeText(tester),
          line,
          reason: s.why('the line reads "$line"'),
        );
        expect(_badgeSeats(tester), <int>[
          2,
        ], reason: s.why('the badge is on seat 2 when the line is'));
        await s.pump(16);
        expect(_deadLines(said), <String>[
          line,
        ], reason: s.why('one announcement; all: ${said.recorded}'));
        await s.pump(1400 - 16);
        expect(
          find.byKey(_otherNoticeKey),
          findsOneWidget,
          reason: s.why('still up 1400 ms after it appeared (${shownMs}ms in)'),
        );
        await s.pump(200);
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('gone 1600 ms after it appeared'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // (c): a moved-path dead end has no throw of that seat pending: armed at once.
  for (final bool oneFace in const <bool>[true, false]) {
    testWidgets('C-589 D1 (c): a moved-path dead end with '
        '${oneFace ? 'one dead face' : 'two dead faces'} and no throw pending '
        'is armed at once: line, one announcement, ${oneFace ? 'badge' : 'no '
                  'badge'}, held 1500 ms from the frames', (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0, other: const <int>[10, -1, -1, -1]),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 moved path, '
        '${oneFace ? 'one' : 'two'} dead face(s)',
        tester,
        drive,
      );
      final String line = _noMoveOtherEn('Bob');
      try {
        said.recorded.clear();
        if (oneFace) {
          await _movedPathOneDead(s, seat: 2, next: 0);
        } else {
          await _movedPathTwoDead(s, seat: 2, next: 0);
        }
        expect(
          find.byKey(opponentThrowKey(2)),
          findsNothing,
          reason: s.why('fixture: no throw of seat 2 is pending'),
        );
        await s.pump(16);
        expect(
          _otherNoticeText(tester),
          line,
          reason: s.why('the line is up on the first frame after the push'),
        );
        expect(
          _badgeSeats(tester),
          oneFace ? <int>[2] : isEmpty,
          reason: s.why(
            oneFace
                ? 'the badge is on seat 2 on the first frame'
                : 'no badge with two dead faces',
          ),
        );
        expect(
          _deadLines(said),
          <String>[line],
          reason: s.why(
            'exactly one announcement at once; all announcements: '
            '${said.recorded}',
          ),
        );
        await s.pump(1400 - 16);
        expect(
          find.byKey(_otherNoticeKey),
          findsOneWidget,
          reason: s.why('the line is up 1400 ms after the frames'),
        );
        await s.pump(200);
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('the line is gone 1600 ms after the frames'),
        );
        expect(
          _badgeSeats(tester),
          isEmpty,
          reason: s.why('the badge is gone 1600 ms after the frames'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });
  }

  // (d): superseded before the landing.
  testWidgets(
    'C-589 D2 (d): a new game before the landing drops the pending dead end: '
    'no line, no badge, no announcement, ever',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final List<Map<String, Object?>> seats = _pair(mySeat: 0);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        seats: seats,
        turn: _awaitRoll(2),
        gameId: 'game-a',
      );
      await mountGame(tester, drive);
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead roll, new game',
        tester,
        drive,
      );
      try {
        said.recorded.clear();
        await _singleDeadRoll(s, seat: 2, next: 0);
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('fixture: the dead roll\'s die is in the air'),
        );
        await s.frames(
          limitMs: 96,
          each: (int ms) => _expectNothingYet(s, tester, said, ms),
        );
        await s.push(
          'room',
          roomData(seats: seats, turn: _awaitRoll(0), gameId: 'game-b'),
        );
        _expectNothingYet(s, tester, said, 96);
        await s.frames(
          limitMs: 3000,
          each: (int ms) => _expectNothingYet(s, tester, said, 96 + ms),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-589 D2 (d): a resync snapshot that clears the throws before the '
    'landing drops the pending dead end, and a later ordinary throw of the '
    'same seat does not light it up',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final List<Map<String, Object?>> seats = _pair(
        mySeat: 0,
        other: const <int>[10, -1, -1, -1],
      );
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: seats,
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead roll, resync',
        tester,
        drive,
      );
      try {
        said.recorded.clear();
        await _singleDeadRoll(s, seat: 2, next: 0);
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('fixture: the dead roll\'s die is in the air'),
        );
        await s.frames(
          limitMs: 96,
          each: (int ms) => _expectNothingYet(s, tester, said, ms),
        );
        await s.push('room', roomData(seats: seats, turn: _awaitRoll(2, k: 4)));
        expect(
          find.byKey(opponentThrowKey(2)),
          findsNothing,
          reason: s.why('fixture: the resync took the dead roll\'s die away'),
        );
        _expectNothingYet(s, tester, said, 96);
        await s.frames(
          limitMs: 1600,
          each: (int ms) => _expectNothingYet(s, tester, said, 96 + ms),
        );
        // Seat 2 rolls again and has a move: its landing must not arm the
        // dead end the resync dropped.
        await s.push('rolled', _rolled(2, 5, 5, legal: const <int>[0]));
        await s.push(
          'turn',
          turnJson(
            seat: 2,
            phase: 'await_move',
            k: 5,
            value: 5,
            legal: const <int>[0],
            queue: const <int>[5],
            legalByFace: <Map<String, Object?>>[
              faceLegal(5, const <int>[0]),
            ],
          ),
        );
        final int landedMs = await s.frames(
          limitMs: 1500,
          until: () => tester.any(find.byKey(seatDieFaceKey(2, 5))),
          each: (int ms) => _expectNothingYet(s, tester, said, ms),
        );
        expect(
          landedMs,
          isNot(-1),
          reason: s.why('fixture: seat 2\'s new die lands on its 5'),
        );
        await s.frames(
          limitMs: 1800,
          each: (int ms) => _expectNothingYet(s, tester, said, ms),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-589 D2 (d): the screen disposed before the landing: no exception and '
    'no announcement afterwards',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead roll, dispose',
        tester,
        drive,
      );
      said.recorded.clear();
      await _singleDeadRoll(s, seat: 2, next: 0);
      await s.pump(96);
      await releaseGame(tester, drive);
      await s.pump(3000);
      expect(
        tester.takeException(),
        isNull,
        reason: s.why('no exception after the screen went away mid-throw'),
      );
      expect(
        _deadLines(said),
        isEmpty,
        reason: s.why(
          'no dead-end announcement after dispose; all announcements: '
          '${said.recorded}',
        ),
      );
    },
  );

  testWidgets(
    'C-589 D2 (d): a newer dead end replaces a pending one: only the newer '
    'seat\'s line and badge ever show, one announcement',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await _mount(
        tester,
        mySeat: 1,
        players: 4,
        turn: _awaitRoll(3),
        seats: _quad(mySeat: 1),
      );
      final _Scn s = _Scn(
        'four seats, me=1, seat 3 dead roll pending, then seat 0 dead roll',
        tester,
        drive,
      );
      final String older = _noMoveOtherEn('Dan');
      final String newer = _noMoveOtherEn('Ann');
      try {
        said.recorded.clear();
        await _singleDeadRoll(s, seat: 3, next: 0);
        await _singleDeadRoll(s, seat: 0, next: 1, face: 4, k: 2);
        expect(
          find.byKey(opponentThrowKey(0)),
          findsNothing,
          reason: s.why('fixture: seat 0\'s throw is queued behind seat 3\'s'),
        );
        final int landedMs = await s.frames(
          limitMs: 3000,
          until: () => tester.any(find.byKey(seatDieFaceKey(0, 4))),
          each: (int ms) {
            expect(
              _otherNoticeText(tester),
              isNull,
              reason: s.why(
                'no line while seat 0\'s die is not down (${ms}ms); the '
                'older pending dead end of seat 3 must have been replaced',
              ),
            );
            expect(
              _badgeSeats(tester),
              isEmpty,
              reason: s.why(
                'no badge while seat 0\'s die is not down (${ms}ms)',
              ),
            );
          },
        );
        expect(landedMs, isNot(-1), reason: s.why('seat 0\'s die lands'));
        expect(
          _otherNoticeText(tester),
          newer,
          reason: s.why('at the landing the line names Ann, not Dan'),
        );
        expect(_badgeSeats(tester), <int>[
          0,
        ], reason: s.why('the badge is on seat 0 only'));
        await s.pump(1700);
        expect(
          _deadLines(said),
          <String>[newer],
          reason: s.why(
            '"$older" is never announced and "$newer" once; all '
            'announcements: ${said.recorded}',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'C-589 D2: my own dead end before the watcher dead end lands keeps the '
    'slot; the landing still arms the watcher hold (one announcement) and '
    'it ends 1500 ms after the landing',
    (tester) async {
      final _Announcements said = _Announcements();
      said.install(tester);
      addTearDown(() => said.remove(tester));
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead pending then my dead roll',
        tester,
        drive,
      );
      final String line = _noMoveOtherEn('Bob');
      try {
        said.recorded.clear();
        await _singleDeadRoll(s, seat: 2, next: 0);
        await s.pump(48);
        await _singleDeadRoll(s, seat: 0, next: 2, face: 4, k: 2);
        await s.pump(16);
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason: s.why('my own notice is up'),
        );
        final int landedMs = await s.frames(
          limitMs: 1500,
          until: () => tester.any(find.byKey(seatDieFaceKey(2, 3))),
        );
        expect(landedMs, isNot(-1), reason: s.why('seat 2\'s die lands'));
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason: s.why('my own notice keeps the slot at the landing'),
        );
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('the watcher line does not take the slot from mine'),
        );
        await s.pump(16);
        expect(
          _deadLines(said),
          <String>[line],
          reason: s.why(
            'the landing still announces the watcher line once; all '
            'announcements: ${said.recorded}',
          ),
        );
        await s.pump(1600);
        expect(
          find.byKey(_otherNoticeKey),
          findsNothing,
          reason: s.why('the watcher hold is over 1600 ms after the landing'),
        );
        expect(
          _badgeSeats(tester),
          isEmpty,
          reason: s.why('no badge 1600 ms after the landing'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // (e): the badge lives exactly as long as the line.
  testWidgets(
    'C-589 D1 (e): the badge and the line appear on the same frame and '
    'disappear on the same frame, 1500 ms apart',
    (tester) async {
      final RollTrayDrive drive = await _mount(
        tester,
        turn: _awaitRoll(2),
        seats: _pair(mySeat: 0),
      );
      final _Scn s = _Scn(
        'two seats, me=0, seat 2 dead roll, lifetimes',
        tester,
        drive,
      );
      try {
        await _singleDeadRoll(s, seat: 2, next: 0);
        final List<(int, bool, bool)> seen = <(int, bool, bool)>[];
        final int landedMs = await s.frames(
          limitMs: 1500,
          until: () => tester.any(find.byKey(seatDieFaceKey(2, 3))),
        );
        expect(landedMs, isNot(-1), reason: s.why('seat 2\'s die lands'));
        seen.add((0, _noticeUp(tester), _badgeSeats(tester).contains(2)));
        for (int ms = 16; ms <= 2000; ms += 16) {
          await tester.pump(_kFrame);
          seen.add((ms, _noticeUp(tester), _badgeSeats(tester).contains(2)));
        }
        s.steps.add('pumped 2000ms frame by frame from the landing');
        for (final (int, bool, bool) frame in seen) {
          expect(
            frame.$2,
            frame.$3,
            reason: s.why(
              'the line (${frame.$2}) and the badge (${frame.$3}) share a '
              'frame, ${frame.$1}ms after the landing',
            ),
          );
        }
        expect(
          seen.first.$2,
          isTrue,
          reason: s.why('both are on the landing frame'),
        );
        final int goneAt = seen.firstWhere((f) => !f.$2).$1;
        expect(
          goneAt,
          inInclusiveRange(_kHoldMs - 20, _kHoldMs + 20),
          reason: s.why(
            'both go $goneAt ms after the landing; the hold is $_kHoldMs ms '
            'from the landing',
          ),
        );
        expect(
          seen.where((f) => f.$1 > goneAt && f.$2),
          isEmpty,
          reason: s.why('neither comes back after it went'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}
