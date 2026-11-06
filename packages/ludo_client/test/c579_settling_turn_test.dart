// Controller proof for C-579 D4 (order 579t): the placeholder turn says it is
// a placeholder. Written from the contract's text alone. A real
// RoomController on FakeTransport, every state a decoded wire frame, driven
// with the frame helpers from support/roll_tray_harness.dart.
//
// `TurnState.settling` is the contract's new name, so this file does not
// compile on a tree without it. Every compile error on such a tree must be
// that one name and nothing else.
//
// Every failure reason starts with the scenario name and ends with the
// frames that led to it, so a red case replays from its message.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

/// A prior turn with values no default can produce, so a placeholder that
/// copies them is told apart from one that invents them.
const int _priorK = 7;
const int _priorSegmentMs = 30000;

Map<String, Object?> _moveTurn() => <String, Object?>{
  ...turnJson(
    seat: 0,
    phase: 'await_move',
    k: _priorK,
    value: 4,
    legal: const <int>[1, 3],
  ),
  'segment_ms': _priorSegmentMs,
};

Map<String, Object?> _rollTurn() => <String, Object?>{
  ...turnJson(seat: 0, phase: 'await_roll', k: _priorK),
  'segment_ms': _priorSegmentMs,
};

List<Map<String, Object?>> _seats() => <Map<String, Object?>>[
  seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
  seatJson(2, name: 'Bob', tokens: const <int>[-1, -1, 40, -1]),
];

/// Controllers opened by the running case; [_test] disposes them inside the
/// test body so a pending resync timer cannot outlive it.
final List<_Case> _opened = <_Case>[];

void _test(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (WidgetTester tester) async {
    try {
      await body(tester);
    } finally {
      for (final _Case c in _opened) {
        c.controller.dispose();
      }
      _opened.clear();
    }
  });
}

class _Case {
  _Case(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];

  RoomController get controller => drive.controller;

  TurnState get turn => controller.room!.turn!;

  String why(String expected) =>
      '$name | expected: $expected | replay: ${steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  Future<void> pushMoved() => push('moved', movedFrame(0, 1, 10, 14));

  Future<void> pushPassed([String reason = 'no_legal_move']) =>
      push('turn_passed', <String, Object?>{'seat': 0, 'reason': reason});
}

Future<_Case> _open(
  WidgetTester tester,
  String name, {
  Map<String, Object?>? turn,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn ?? _moveTurn(),
    seats: _seats(),
  );
  final _Case opened = _Case(name, tester, drive);
  _opened.add(opened);
  return opened;
}

/// The placeholder keeps what the prior turn had, as before C-579.
void _expectPlaceholder(_Case c, TurnState before) {
  final TurnState now = c.turn;
  expect(now.settling, isTrue, reason: c.why('the placeholder is settling'));
  expect(now.seat, before.seat, reason: c.why('same seat as the prior turn'));
  expect(
    now.phase,
    TurnPhase.awaitRoll,
    reason: c.why('the placeholder phase is awaitRoll, as before'),
  );
  expect(
    now.deadlineMs,
    before.deadlineMs,
    reason: c.why('deadlineMs copied from the prior turn'),
  );
  expect(now.k, before.k, reason: c.why('k copied from the prior turn'));
  expect(
    now.segmentMs,
    before.segmentMs,
    reason: c.why('segmentMs copied from the prior turn'),
  );
  expect(now.value, isNull, reason: c.why('value cleared, as before'));
  expect(now.legal, isNull, reason: c.why('legal cleared, as before'));
  expect(now.sixes, isNull, reason: c.why('sixes cleared, as before'));
}

void main() {
  _test('C-579 D4: a TurnState built with no settling argument is not '
      'settling', (tester) async {
    const TurnState turn = TurnState(
      seat: 1,
      phase: TurnPhase.awaitRoll,
      deadlineMs: 1000,
      k: 0,
    );
    expect(turn.settling, isFalse, reason: 'constructor default is false');
  });

  _test(
    'C-579 D4: TurnState.fromJson is never settling, even when the json says '
    'so: the flag is not on the wire',
    (tester) async {
      for (final Object? claim in <Object?>[true, false, 'true', 1, null]) {
        final TurnState turn = TurnState.fromJson(<String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 2,
          'settling': claim,
        });
        expect(
          turn.settling,
          isFalse,
          reason:
              'fromJson with settling: ${jsonEncode(claim)} must read false; '
              'the field is not decoded',
        );
      }
    },
  );

  _test('C-579 D4: the turn in the room snapshot is not settling', (
    tester,
  ) async {
    final _Case c = await _open(tester, 'snapshot at connect');
    expect(c.turn.settling, isFalse, reason: c.why('a snapshot is truth'));
  });

  _test(
    'C-579 D4: after moved the turn is a settling placeholder with the prior '
    'seat, deadline, k and segment; the turn frame then clears it',
    (tester) async {
      final _Case c = await _open(tester, 'moved then turn');
      final TurnState before = c.turn;
      expect(before.settling, isFalse, reason: c.why('fixture: not settling'));
      expect(before.k, _priorK, reason: c.why('fixture: k is $_priorK'));
      expect(
        before.segmentMs,
        _priorSegmentMs,
        reason: c.why('fixture: segment is $_priorSegmentMs'),
      );
      await c.pushMoved();
      _expectPlaceholder(c, before);
      await c.push('turn', turnFrame(0));
      expect(
        c.turn.settling,
        isFalse,
        reason: c.why('the turn frame replaces the placeholder with truth'),
      );
      expect(c.turn.seat, 0, reason: c.why('and it names seat 0'));
    },
  );

  for (final String reason in const <String>['no_legal_move', 'three_sixes']) {
    _test('C-579 D4: after turn_passed ($reason) the turn is a settling '
        'placeholder with the prior seat, deadline, k and segment; the turn '
        'frame then clears it', (tester) async {
      final _Case c = await _open(
        tester,
        'turn_passed $reason then turn',
        turn: _rollTurn(),
      );
      await c.push('rolled', <String, Object?>{
        'seat': 0,
        'value': 3,
        'legal': const <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': _priorK + 1,
        'reveal': rollTrayReveal,
        'queue': const <int>[],
      });
      final TurnState before = c.turn;
      expect(
        before.settling,
        isFalse,
        reason: c.why('fixture: a rolled turn is not settling'),
      );
      await c.pushPassed(reason);
      _expectPlaceholder(c, before);
      await c.push('turn', turnFrame(2));
      expect(
        c.turn.settling,
        isFalse,
        reason: c.why('the next seat\'s turn is truth'),
      );
      expect(c.turn.seat, 2, reason: c.why('and it is seat 2\'s'));
    });
  }

  _test(
    'C-579 D4: moved then turn_passed with no turn between stays settling',
    (tester) async {
      final _Case c = await _open(tester, 'moved then turn_passed');
      await c.pushMoved();
      final TurnState first = c.turn;
      await c.pushPassed();
      expect(
        c.turn.settling,
        isTrue,
        reason: c.why('still a placeholder, no turn frame arrived'),
      );
      expect(c.turn.k, first.k, reason: c.why('k unchanged by the second'));
      expect(c.turn.deadlineMs, first.deadlineMs);
    },
  );

  _test('C-579 D4: rolled clears the placeholder', (tester) async {
    final _Case c = await _open(tester, 'moved then rolled');
    await c.pushMoved();
    expect(c.turn.settling, isTrue, reason: c.why('fixture: settling'));
    await c.push(
      'rolled',
      rolledFrame(0, 6, _priorK + 1, legal: const <int>[0, 1]),
    );
    expect(
      c.turn.settling,
      isFalse,
      reason: c.why('a rolled builds the turn from the frame'),
    );
  });

  _test('C-579 D4: a room snapshot clears the placeholder', (tester) async {
    final _Case c = await _open(tester, 'moved then room');
    await c.pushMoved();
    expect(c.turn.settling, isTrue, reason: c.why('fixture: settling'));
    await c.push(
      'room',
      roomData(
        seats: _seats(),
        turn: turnJson(seat: 2, phase: 'await_roll', k: 9),
      ),
    );
    expect(
      c.turn.settling,
      isFalse,
      reason: c.why('a snapshot replaces the turn with truth'),
    );
    expect(c.turn.seat, 2, reason: c.why('and it is the snapshot\'s turn'));
  });

  _test('C-579 D4: game_over clears the placeholder', (tester) async {
    final _Case c = await _open(tester, 'moved then game_over');
    await c.pushMoved();
    expect(c.turn.settling, isTrue, reason: c.why('fixture: settling'));
    await c.push('game_over', gameOverFrame(0));
    final TurnState? turn = c.controller.room!.turn;
    expect(
      turn?.settling ?? false,
      isFalse,
      reason: c.why('a finished game is not settling'),
    );
  });

  _test(
    'C-579 D4: a moved naming a seat that is not in the room is ignored: the '
    'turn is not turned into a placeholder',
    (tester) async {
      final _Case c = await _open(tester, 'moved by an absent seat');
      await c.push('moved', movedFrame(3, 0, 3, 9));
      expect(
        c.turn.settling,
        isFalse,
        reason: c.why('an ignored frame leaves the turn as it was'),
      );
      expect(c.turn.phase, TurnPhase.awaitMove, reason: c.why('same phase'));
    },
  );

  _test('C-579 D4: a moved with a sequence gap starts a resync and builds no '
      'placeholder', (tester) async {
    final _Case c = await _open(tester, 'moved with a gap');
    c.drive.lastSeq += 2;
    await c.push('moved', movedFrame(0, 1, 10, 14));
    expect(
      c.turn.settling,
      isFalse,
      reason: c.why('a gap is a resync, not a placeholder'),
    );
  });

  _test('C-579 D4: a turn_passed with a reason outside the protocol is ignored '
      'and builds no placeholder', (tester) async {
    final _Case c = await _open(tester, 'turn_passed with a bad reason');
    await c.push('turn_passed', <String, Object?>{
      'seat': 0,
      'reason': 'out_of_time',
    });
    expect(
      c.turn.settling,
      isFalse,
      reason: c.why('a malformed frame leaves the turn as it was'),
    );
  });
}
