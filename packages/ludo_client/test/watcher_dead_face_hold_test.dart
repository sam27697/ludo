// Screen proof for work/ludo/orders/592-seat-moved-host-wiring-x161.md, D4
// (X161): a watcher's red X badge never sits on a faceless die. Written from
// that contract alone, against a GameScreen over a real RoomController on
// FakeTransport (test/support/roll_tray_harness.dart); every state arrives as
// a decoded wire frame.
//
// The contract: while the watcher hold armed for a single dead face is up for
// seat S, the seat die of S shows the face the hold recorded, whatever the
// turn or the face memory say. So at every pump on which
// board-seat-die-dead-S exists, board-seat-die-idle-S does not and
// board-seat-die-face-S-<face> does. When the hold ends the die goes back to
// its usual derivation, and the case after the hold asserts only that the
// badge is gone.
//
// Keys named by the contract:
//   board-seat-die-dead-<seat>   the badge (C-586 D2)
//   board-seat-die-idle-<seat>   the idle pose of a seat die
//   board-seat-die-face-<seat>-<face>   the face pose
//
// Timing: the 589tr probe read the screen about 1.2 s after the frames. Every
// case below is run both with a pump in 100 ms steps from the frames and with
// one 1200 ms stretch first, then 100 ms steps. The hold is 1500 ms from the
// landing of the dead roll's thrown die (C-589), and every walk runs well past
// it. Failure reasons name the scenario and end with the frames and pumps that
// led to the failure; the cases are deterministic, so the scenario is the
// whole reproduction and there is no seed.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

const Duration _kStep = Duration(milliseconds: 100);

/// The hold from C-586, unchanged: 1500 ms from the landing.
const int _kHoldMs = 1500;

/// Long enough to cover the landing (under 700 ms), the hold and a margin.
const int _kWalkMs = 3200;

const int _rolling = 2;
const int _face = 3;

Key _deadBadgeKey(int seat) => Key('board-seat-die-dead-$seat');

const List<int> _yard = <int>[-1, -1, -1, -1];

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

List<Map<String, Object?>> _quad({
  required int mySeat,
}) => <Map<String, Object?>>[
  for (int seat = 0; seat < 4; seat++)
    seatJson(seat, name: seat == mySeat ? 'Sam' : _names[seat]!, tokens: _yard),
];

Map<String, Object?> _turnFrame(int seat, {List<int> queue = const <int>[]}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

Map<String, Object?> _rolled(
  int seat,
  int value,
  int k, {
  List<int> legal = const <int>[],
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': <int>[],
};

class _Scn {
  _Scn(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];
  int elapsedMs = 0;
  int badgeFrames = 0;

  String why(String expected) =>
      '$name | expected: $expected | at ${elapsedMs}ms after the frames | '
      'replay: ${steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) async {
    final Map<String, Object?> brief = <String, Object?>{...data}
      ..remove('reveal')
      ..remove('rules')
      ..remove('chain_commit');
    steps.add('$type ${jsonEncode(brief)}');
    await drive.push(tester, type, data);
  }

  /// Pumps [ms] in one stretch with no check in between.
  Future<void> jump(int ms) async {
    steps.add('pump ${ms}ms in one stretch');
    await tester.pump(Duration(milliseconds: ms));
    elapsedMs += ms;
  }

  /// The contract of D4 at this instant: a badge on seat [_rolling] comes
  /// with the rolled face and without the idle pose.
  void check() {
    if (!tester.any(find.byKey(_deadBadgeKey(_rolling)))) {
      return;
    }
    badgeFrames += 1;
    expect(
      find.byKey(seatDieIdleKey(_rolling)),
      findsNothing,
      reason: why(
        'board-seat-die-idle-$_rolling absent while board-seat-die-dead-'
        '$_rolling is up (an X on a faceless die)',
      ),
    );
    expect(
      find.byKey(seatDieFaceKey(_rolling, _face)),
      findsOneWidget,
      reason: why(
        'board-seat-die-face-$_rolling-$_face (the rolled face) is shown '
        'while the badge is up',
      ),
    );
  }

  /// Pumps in 100 ms steps up to [untilMs] total since the frames, checking
  /// after every step.
  Future<void> walk(int untilMs) async {
    steps.add('walk in ${_kStep.inMilliseconds}ms steps to ${untilMs}ms');
    while (elapsedMs < untilMs) {
      await tester.pump(_kStep);
      elapsedMs += _kStep.inMilliseconds;
      check();
    }
  }

  void expectBadgeSeen() {
    expect(
      badgeFrames,
      greaterThan(0),
      reason: why(
        'fixture: the badge on seat $_rolling was up on at least one pump '
        '(the dead roll arms the hold); it never was',
      ),
    );
  }

  void expectBadgeGone() {
    expect(
      find.byKey(_deadBadgeKey(_rolling)),
      findsNothing,
      reason: why(
        'board-seat-die-dead-$_rolling is gone once the ${_kHoldMs}ms hold '
        'has ended',
      ),
    );
  }
}

Future<(RollTrayDrive, _Scn)> _mountAndRoll(
  WidgetTester tester,
  String name, {
  bool turnPassesAtOnce = true,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    mySeat: 1,
    players: 4,
    turn: turnJson(
      seat: _rolling,
      phase: 'await_roll',
      k: 0,
      queue: const <int>[],
    ),
    seats: _quad(mySeat: 1),
  );
  await mountGame(tester, drive);
  final _Scn s = _Scn(name, tester, drive);
  await s.push('rolled', _rolled(_rolling, _face, 1));
  await s.push('turn_passed', <String, Object?>{
    'seat': _rolling,
    'reason': 'no_legal_move',
  });
  if (turnPassesAtOnce) {
    await s.push('turn', _turnFrame(3));
  }
  return (drive, s);
}

void main() {
  // ===========================================================================
  // (i): seat 2 rolls one face with no legal move, nothing else happens.
  // ===========================================================================
  group('X161 (i): the badge never sits on an idle die', () {
    testWidgets('pumped in 100 ms steps from the frames', (tester) async {
      final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
        tester,
        'four seats, me=1, seat 2 dead roll of 3, 100ms steps',
      );
      try {
        s.check();
        await s.walk(_kWalkMs);
        s.expectBadgeSeen();
        s.expectBadgeGone();
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('after a 1200 ms stretch (the 589tr probe timing), then 100 ms '
        'steps', (tester) async {
      final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
        tester,
        'four seats, me=1, seat 2 dead roll of 3, 1200ms stretch first',
      );
      try {
        await s.jump(1200);
        s.check();
        await s.walk(_kWalkMs);
        s.expectBadgeSeen();
        s.expectBadgeGone();
      } finally {
        await releaseGame(tester, drive);
      }
    });
  });

  // ===========================================================================
  // (j): the next turn frame arrives while the hold is up.
  // ===========================================================================
  group('X161 (j): the next seat\'s turn arrives during the hold', () {
    for (final int firstStretch in const <int>[0, 1200]) {
      testWidgets('turn for seat 3 pushed once the badge is up '
          '(first stretch ${firstStretch}ms)', (tester) async {
        final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
          tester,
          'four seats, me=1, seat 2 dead roll of 3, turn for seat 3 '
          'during the hold, first stretch ${firstStretch}ms',
          turnPassesAtOnce: false,
        );
        try {
          if (firstStretch > 0) {
            await s.jump(firstStretch);
          }
          s.check();
          // Step until the badge shows (the landing), bounded.
          int guard = 0;
          while (!tester.any(find.byKey(_deadBadgeKey(_rolling))) &&
              guard < 30) {
            await s.walk(s.elapsedMs + _kStep.inMilliseconds);
            guard += 1;
          }
          expect(
            find.byKey(_deadBadgeKey(_rolling)),
            findsOneWidget,
            reason: s.why(
              'fixture: the badge on seat $_rolling is up before the turn '
              'frame is pushed',
            ),
          );
          await s.push('turn', _turnFrame(3));
          s.check();
          await s.walk(_kWalkMs + s.elapsedMs);
          s.expectBadgeGone();
        } finally {
          await releaseGame(tester, drive);
        }
      });
    }

    testWidgets('seat 3 then rolls with a legal move during the hold', (
      tester,
    ) async {
      final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
        tester,
        'four seats, me=1, seat 2 dead roll of 3, then seat 3 rolls a 4 with '
        'a legal move during the hold',
      );
      try {
        int guard = 0;
        while (!tester.any(find.byKey(_deadBadgeKey(_rolling))) && guard < 30) {
          await s.walk(s.elapsedMs + _kStep.inMilliseconds);
          guard += 1;
        }
        expect(
          find.byKey(_deadBadgeKey(_rolling)),
          findsOneWidget,
          reason: s.why('fixture: the badge on seat $_rolling is up'),
        );
        await s.push('rolled', _rolled(3, 4, 1, legal: const <int>[0]));
        s.check();
        await s.walk(_kWalkMs + s.elapsedMs);
        s.expectBadgeGone();
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets('a room snapshot (a resync) lands during the hold and drops '
        'the face memory', (tester) async {
      final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
        tester,
        'four seats, me=1, seat 2 dead roll of 3, a room snapshot during '
        'the hold',
      );
      try {
        int guard = 0;
        while (!tester.any(find.byKey(_deadBadgeKey(_rolling))) && guard < 30) {
          await s.walk(s.elapsedMs + _kStep.inMilliseconds);
          guard += 1;
        }
        expect(
          find.byKey(_deadBadgeKey(_rolling)),
          findsOneWidget,
          reason: s.why('fixture: the badge on seat $_rolling is up'),
        );
        await s.push(
          'room',
          roomData(
            seats: _quad(mySeat: 1),
            players: 4,
            turn: turnJson(
              seat: 3,
              phase: 'await_roll',
              k: 1,
              queue: const <int>[],
            ),
          ),
        );
        s.check();
        await s.walk(_kWalkMs + s.elapsedMs);
        s.expectBadgeGone();
      } finally {
        await releaseGame(tester, drive);
      }
    });
  });

  // ===========================================================================
  // (k): after the hold.
  // ===========================================================================
  group('X161 (k): after the hold', () {
    testWidgets('the badge is gone; the die is whatever the usual derivation '
        'gives', (tester) async {
      final (RollTrayDrive drive, _Scn s) = await _mountAndRoll(
        tester,
        'four seats, me=1, seat 2 dead roll of 3, read after the hold',
      );
      try {
        await s.walk(_kWalkMs);
        s.expectBadgeSeen();
        s.expectBadgeGone();
        expect(
          find.byKey(seatDieKey(_rolling)),
          findsOneWidget,
          reason: s.why(
            'board-seat-die-$_rolling is still drawn after the hold (only the '
            'badge goes)',
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: s.why('no exception while the hold ends'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });
  });
}
