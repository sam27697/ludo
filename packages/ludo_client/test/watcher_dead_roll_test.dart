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

  /// The moment the thrown die has landed on its seat (the throw tumbles for
  /// 700 ms and no seat die is drawn meanwhile): pumps 800 ms of frames and
  /// returns 800 if [done] holds then, else -1. The hold, armed when the dead
  /// end frames arrived, has 700 ms left at this point.
  Future<int> landed(bool Function() done) async {
    await pump(800);
    if (done()) {
      return 800;
    }
    steps.add('condition did not hold 800ms after the dead end frames');
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
            final int waited = await s.landed(() => _noticeUp(tester));
            expect(
              waited,
              isNot(-1),
              reason: s.why(
                'game-no-move-other-notice appears for seat $rolling',
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
            await s.pump(600);
            expect(
              find.byKey(_otherNoticeKey),
              findsOneWidget,
              reason: s.why(
                'the line is still up at 1400 ms, inside the $_kHoldMs ms '
                'hold',
              ),
            );
            expect(_badgeSeats(tester), <int>[
              rolling,
            ], reason: s.why('the badge is still up at 1400 ms'));
            await s.pump(300);
            expect(
              find.byKey(_otherNoticeKey),
              findsNothing,
              reason: s.why('the line is gone at 1700 ms, after the hold'),
            );
            expect(
              _badgeSeats(tester),
              isEmpty,
              reason: s.why('the badge is gone at 1700 ms, after the hold'),
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
}
