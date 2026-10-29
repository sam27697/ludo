// C-495: the countdown ring measures the running segment.
// Written from that contract. TurnState.segmentMs is not on this branch, so
// every case that needs it reads the getter through dynamic and fails when
// the getter is missing or the value is wrong. remainingFraction and color
// are read off game-header-countdown-ring the same way play_header_test.dart
// reads color. That file is not imported and not edited.
//
// The screen cases drive GameScreen on the fake connection. Time moves only
// by tester.pump(duration). A live countdown never meets pumpAndSettle.
//
// Ambiguities, reported and not invented around:
//   - "a turn push that restarts the same seat at 45000" is read as
//     segment_ms 45000 and deadline_ms 45000. A new segment opens with its
//     whole budget left, which is what snapping the ring to 1.0 requires,
//     and the countdown restarts only when the deadline changes.
//   - TurnState has no toJson. Decision 1's toJson sentence is not in the
//     Tests section, and there is no method to call, so it is not tested.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _ringKey = Key('game-header-countdown-ring');

const Object _omit = Object();

/// `turn.segmentMs`, one dynamic lookup. A missing getter fails the case
/// instead of compiling it out.
Object? _segmentMs(Object turn, {required String caseName}) {
  try {
    return (turn as dynamic).segmentMs as Object?;
  } on NoSuchMethodError {
    fail(
      'C-495 decision 1: TurnState must expose segmentMs. Case "$caseName" '
      'cannot read it (NoSuchMethodError).',
    );
  }
}

Map<String, Object?> _turnMap({
  int seat = 1,
  int deadlineMs = 30000,
  int k = 0,
  Object? segmentMs = _omit,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': deadlineMs,
  'k': k,
  if (!identical(segmentMs, _omit)) 'segment_ms': segmentMs,
};

Map<String, Object?> _seatMap(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomMap(Map<String, Object?> turn) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Object?>[_seatMap(0, 'Sam'), _seatMap(1, 'Bob')],
  'turn': turn,
  'winner': null,
  'seq': 1,
};

TurnState _parseTurn(Map<String, Object?> turn) => TurnState.fromJson(turn);

TurnState _parseRoomTurn(Map<String, Object?> turn) {
  final RoomSnapshot room = RoomSnapshot.fromJson(_roomMap(turn));
  expect(room.turn, isNotNull, reason: 'fixture: the room carries a turn');
  return room.turn!;
}

/// The ring's own fields, through dynamic, as play_header_test.dart reads
/// `color`. RGB only: the contract names no alpha.
double _ringFraction(WidgetTester tester) {
  final dynamic ring = tester.widget(find.byKey(_ringKey));
  return ring.remainingFraction as double;
}

Color _ringColor(WidgetTester tester) {
  final dynamic ring = tester.widget(find.byKey(_ringKey));
  return ring.color as Color;
}

bool _sameRgb(Color a, Color b) => a.r == b.r && a.g == b.g && a.b == b.b;

void _expectFraction(WidgetTester tester, double fraction, String why) {
  final double got = _ringFraction(tester);
  expect(got, closeTo(fraction, 0.001), reason: '$why; measured $got');
}

void _expectColor(WidgetTester tester, Color color, String why) {
  final Color got = _ringColor(tester);
  expect(
    _sameRgb(got, color),
    isTrue,
    reason: '$why; measured $got, expected $color',
  );
}

Future<RollTrayDrive> _mountRing(
  WidgetTester tester,
  Map<String, Object?> turn,
) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(tester, turn: turn);
  await mountGame(tester, drive);
  expect(
    find.byKey(_ringKey),
    findsOneWidget,
    reason: 'fixture: game-header-countdown-ring is on screen',
  );
  return drive;
}

void main() {
  group('snapshot', () {
    test('segment_ms 10000 parses to 10000', () {
      const String name = 'segment_ms 10000 parses to 10000';
      final Map<String, Object?> turn = _turnMap(segmentMs: 10000);
      expect(_segmentMs(_parseTurn(turn), caseName: name), 10000);
      expect(_segmentMs(_parseRoomTurn(turn), caseName: '$name room'), 10000);
    });

    test('absent segment_ms is null, and explicit null is null', () {
      const String name =
          'absent segment_ms is null, and explicit null is null';
      expect(_segmentMs(_parseTurn(_turnMap()), caseName: name), isNull);
      expect(
        _segmentMs(_parseRoomTurn(_turnMap()), caseName: '$name room'),
        isNull,
      );
      final Map<String, Object?> explicit = _turnMap(segmentMs: null);
      expect(
        _segmentMs(_parseTurn(explicit), caseName: '$name explicit'),
        isNull,
      );
      expect(
        _segmentMs(_parseRoomTurn(explicit), caseName: '$name explicit room'),
        isNull,
      );
    });

    test('a string segment_ms is SnapshotFormatException(segment_ms)', () {
      final Map<String, Object?> turn = _turnMap(segmentMs: '10000');
      expect(
        () => TurnState.fromJson(turn),
        throwsA(
          isA<SnapshotFormatException>().having(
            (SnapshotFormatException e) => e.reason,
            'reason',
            'segment_ms',
          ),
        ),
      );
      expect(
        () => RoomSnapshot.fromJson(_roomMap(turn)),
        throwsA(
          isA<SnapshotFormatException>().having(
            (SnapshotFormatException e) => e.reason,
            'reason',
            'segment_ms',
          ),
        ),
      );
    });
  });

  group('reducers', () {
    testWidgets('a turn frame with no segment_ms and deadline_ms 10000 gives '
        'segmentMs 10000', (tester) async {
      const String name =
          'a turn frame with no segment_ms and deadline_ms 10000 '
          'gives segmentMs 10000';
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: _turnMap(),
      );
      try {
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 10000,
        });
        final TurnState? turn = drive.controller.room?.turn;
        expect(turn, isNotNull, reason: 'fixture: the turn frame landed');
        expect(turn!.deadlineMs, 10000, reason: 'fixture: deadline_ms 10000');
        expect(_segmentMs(turn, caseName: name), 10000);
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets(
      'a turn frame with segment_ms 45000 and deadline_ms 30000 gives '
      '45000',
      (tester) async {
        const String name =
            'a turn frame with segment_ms 45000 and deadline_ms 30000 '
            'gives 45000';
        final RollTrayDrive drive = await connectPlaying(
          tester,
          turn: _turnMap(),
        );
        try {
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 1,
            'segment_ms': 45000,
            'deadline_ms': 30000,
          });
          final TurnState? turn = drive.controller.room?.turn;
          expect(turn, isNotNull, reason: 'fixture: the turn frame landed');
          expect(
            turn!.deadlineMs,
            30000,
            reason: 'fixture: deadline_ms stayed 30000',
          );
          expect(_segmentMs(turn, caseName: name), 45000);
        } finally {
          drive.controller.dispose();
        }
      },
    );

    testWidgets(
      'a rolled with a legal move and deadline_ms 10000 gives segmentMs '
      '10000',
      (tester) async {
        const String name =
            'a rolled with a legal move and deadline_ms 10000 gives '
            'segmentMs 10000';
        final RollTrayDrive drive = await connectPlaying(
          tester,
          turn: _turnMap(),
        );
        try {
          await drive.push(tester, 'rolled', <String, Object?>{
            'seat': 1,
            'value': 5,
            'legal': <int>[0],
            'deadline_ms': 10000,
            'k': 1,
            'reveal': rollTrayReveal,
          });
          final TurnState? turn = drive.controller.room?.turn;
          expect(turn, isNotNull, reason: 'fixture: the rolled frame landed');
          expect(
            turn!.phase,
            TurnPhase.awaitMove,
            reason: 'fixture: a move is pending',
          );
          expect(turn.deadlineMs, 10000, reason: 'fixture: deadline_ms 10000');
          expect(_segmentMs(turn, caseName: name), 10000);
        } finally {
          drive.controller.dispose();
        }
      },
    );

    testWidgets(
      'a rolled with legal empty and deadline_ms 4200 after a turn of '
      '10000 keeps 10000',
      (tester) async {
        const String name =
            'a rolled with legal empty and deadline_ms 4200 after a turn '
            'of 10000 keeps 10000';
        final RollTrayDrive drive = await connectPlaying(
          tester,
          turn: _turnMap(),
        );
        try {
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 1,
            'deadline_ms': 10000,
          });
          final TurnState? opened = drive.controller.room?.turn;
          expect(
            opened,
            isNotNull,
            reason: 'fixture: the turn of 10000 landed',
          );
          expect(_segmentMs(opened!, caseName: '$name after the turn'), 10000);
          await drive.push(tester, 'rolled', <String, Object?>{
            'seat': 1,
            'value': 5,
            'legal': <int>[],
            'deadline_ms': 4200,
            'k': 1,
            'reveal': rollTrayReveal,
          });
          final TurnState? kept = drive.controller.room?.turn;
          expect(kept, isNotNull, reason: 'fixture: the rolled frame landed');
          expect(kept!.deadlineMs, 4200, reason: 'fixture: deadline_ms 4200');
          expect(kept.legal, isEmpty, reason: 'fixture: legal is empty');
          expect(_segmentMs(kept, caseName: name), 10000);
        } finally {
          drive.controller.dispose();
        }
      },
    );

    testWidgets('game_started gives segmentMs turn_seconds * 1000', (
      tester,
    ) async {
      const String name = 'game_started gives segmentMs turn_seconds * 1000';
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: _turnMap(),
      );
      try {
        final int expected = drive.controller.room!.rules.turnSeconds * 1000;
        await drive.push(tester, 'game_started', <String, Object?>{
          'turn': 1,
          'game_id': 'c495-game',
          'client_seeds': 'a,b',
        });
        final TurnState? turn = drive.controller.room?.turn;
        expect(turn, isNotNull, reason: 'fixture: game_started landed');
        expect(
          turn!.deadlineMs,
          expected,
          reason: 'fixture: deadlineMs is turn_seconds * 1000',
        );
        expect(_segmentMs(turn, caseName: name), expected);
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets('a moved frame keeps the turn segmentMs', (tester) async {
      const String name = 'a moved frame keeps the turn segmentMs';
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: _turnMap(),
      );
      try {
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 10000,
        });
        final TurnState? opened = drive.controller.room?.turn;
        expect(opened, isNotNull, reason: 'fixture: the turn of 10000 landed');
        expect(_segmentMs(opened!, caseName: '$name after the turn'), 10000);
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 1,
          'token': 0,
          'from': -1,
          'to': 0,
          'captured': <Object?>[],
          'extra_roll': false,
        });
        final TurnState? kept = drive.controller.room?.turn;
        expect(kept, isNotNull, reason: 'fixture: the moved frame landed');
        expect(kept!.seat, 1, reason: 'fixture: the turn seat was carried');
        expect(_segmentMs(kept, caseName: name), 10000);
      } finally {
        drive.controller.dispose();
      }
    });
  });

  group('ring', () {
    testWidgets(
      'segment_ms 10000 and deadline_ms 10000: full, then 0.4, then red '
      'at 3 s',
      (tester) async {
        final RollTrayDrive drive = await _mountRing(
          tester,
          _turnMap(deadlineMs: 10000, segmentMs: 10000),
        );
        try {
          _expectFraction(tester, 1.0, 'a 10000 ms segment opens full');
          _expectColor(
            tester,
            LudoColors.seats[1],
            '10 s left on a 10 s budget is the seat colour, not red',
          );
          await tester.pump(const Duration(seconds: 6));
          _expectFraction(tester, 0.4, '6 s later, 4 s left, fraction 0.4');
          _expectColor(
            tester,
            LudoColors.seats[1],
            '4 s left on a 10 s budget stays the seat colour',
          );
          await tester.pump(const Duration(seconds: 1));
          _expectFraction(
            tester,
            0.3,
            'one more second, 3 s left, fraction 0.3',
          );
          _expectColor(
            tester,
            LudoColors.error,
            '3 s left on a 10 s budget is red',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'segment_ms 45000 and deadline_ms 30000: fraction 30/45, red at '
      '10 s left',
      (tester) async {
        final RollTrayDrive drive = await _mountRing(
          tester,
          _turnMap(deadlineMs: 30000, segmentMs: 45000),
        );
        try {
          expect(
            drive.controller.room!.rules.turnSeconds,
            45,
            reason:
                'fixture: turn_seconds is 45, and (45000 + 999) ~/ 1000 is '
                '45, so both budgets are 45 s',
          );
          _expectFraction(tester, 30 / 45, '30 s left of a 45 s budget');
          _expectColor(
            tester,
            LudoColors.seats[1],
            '30 s left is the seat colour',
          );
          await tester.pump(const Duration(seconds: 20));
          _expectFraction(tester, 10 / 45, '20 s later, 10 s left');
          _expectColor(
            tester,
            LudoColors.error,
            '10 s left of a 45 s budget is red',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'no segment_ms, deadline_ms 30000: fraction against turn_seconds, '
      'as today',
      (tester) async {
        final RollTrayDrive drive = await _mountRing(
          tester,
          _turnMap(deadlineMs: 30000),
        );
        try {
          final int turnSeconds = drive.controller.room!.rules.turnSeconds;
          _expectFraction(
            tester,
            30 / turnSeconds,
            'an old server: 30 s left over turn_seconds',
          );
          _expectColor(
            tester,
            LudoColors.seats[1],
            '30 s left is the seat colour, as today',
          );
          await tester.pump(const Duration(seconds: 20));
          _expectFraction(
            tester,
            10 / turnSeconds,
            '20 s later, 10 s left over turn_seconds',
          );
          _expectColor(tester, LudoColors.error, '10 s left is red, as today');
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets(
      'a turn push at 45000 after a 10000 segment snaps the ring to 1.0',
      (tester) async {
        final RollTrayDrive drive = await _mountRing(
          tester,
          _turnMap(deadlineMs: 10000, segmentMs: 10000),
        );
        try {
          _expectFraction(
            tester,
            1.0,
            'the 10000 ms segment opens full, before the restart',
          );
          _expectColor(
            tester,
            LudoColors.seats[1],
            'that full short budget is the seat colour',
          );
          await tester.pump(const Duration(seconds: 6));
          _expectFraction(
            tester,
            0.4,
            'the short budget has moved, so the snap is a change',
          );
          await drive.push(tester, 'turn', <String, Object?>{
            'seat': 1,
            'segment_ms': 45000,
            'deadline_ms': 45000,
          });
          _expectFraction(
            tester,
            1.0,
            'the same seat restarted at 45000 snaps back to full',
          );
          _expectColor(
            tester,
            LudoColors.seats[1],
            'a full 45 s budget is the seat colour',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  });
}
