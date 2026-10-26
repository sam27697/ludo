// Screen proof for the roll tray (order 366, contract K1-K11), migrated by
// order 463 to C-462: the tray is a read-only record, the face is picked on
// the token (test/token_face_pick_test.dart holds the picker's own cases).
// GameScreen is driven through RoomController on FakeTransport.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/snapshot.dart';

import 'support/roll_tray_harness.dart';

const List<Map<String, Object?>> _sixAndThreeLegal = <Map<String, Object?>>[
  <String, Object?>{
    'face': 6,
    'tokens': <int>[0, 1, 2, 3],
  },
  <String, Object?>{
    'face': 3,
    'tokens': <int>[0],
  },
];

Future<void> _pushQueuedSix(
  WidgetTester tester,
  RollTrayDrive drive,
  List<int> queue,
  int k,
) async {
  await drive.push(tester, 'rolled', <String, Object?>{
    'seat': 0,
    'value': 6,
    'legal': <int>[],
    'deadline_ms': rollTrayDeadlineMs,
    'k': k,
    'reveal': rollTrayReveal,
    'queue': queue,
  });
  await drive.push(tester, 'turn', <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': queue,
  });
}

/// 6, then 6, then 3. The 3's rolled frame carries legal_by_face and is
/// the last frame (PROTOCOL 21.3: a roll that leaves a move pending).
Future<void> _pushSixSixThree(WidgetTester tester, RollTrayDrive drive) async {
  await _pushQueuedSix(tester, drive, const <int>[6], 1);
  await _pushQueuedSix(tester, drive, const <int>[6, 6], 2);
  await drive.push(tester, 'rolled', <String, Object?>{
    'seat': 0,
    'value': 3,
    'legal': <int>[0, 1, 2, 3],
    'deadline_ms': rollTrayDeadlineMs,
    'k': 3,
    'reveal': rollTrayReveal,
    'queue': <int>[6, 6, 3],
    'legal_by_face': _sixAndThreeLegal,
  });
}

Future<RollTrayDrive> _mountQueue(
  WidgetTester tester, {
  required Map<String, Object?> turn,
  List<Map<String, Object?>>? seats,
  Locale locale = const Locale('en'),
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
  );
  await mountGame(tester, drive, locale: locale);
  return drive;
}

void _expectChild(WidgetTester tester, Key parent, Key child, String reason) {
  expect(
    find.descendant(of: find.byKey(parent), matching: find.byKey(child)),
    findsOneWidget,
    reason: reason,
  );
}

void main() {
  testWidgets('case 1: 6, 6 then 3 shows three tray dice with no selection '
      'mark and the big die on turn.value', (tester) async {
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
    );
    try {
      await mountGame(tester, drive);
      await _pushSixSixThree(tester, drive);

      final TurnState turn = drive.controller.room!.turn!;
      expect(drive.controller.room!.seq, 6, reason: 'fixture is broken');
      expect(turn.phase, TurnPhase.awaitMove, reason: 'fixture is broken');
      expect(turn.queue, <int>[6, 6, 3], reason: 'fixture is broken');
      expect(turn.value, 3, reason: 'fixture is broken: rolled value is 3');
      expect(turn.legalByFace, isNotNull, reason: 'fixture is broken');
      expect(find.byKey(boardKey), findsOneWidget, reason: 'fixture is broken');

      expect(
        find.byKey(rollTrayKey),
        findsOneWidget,
        reason:
            'K1: game-roll-tray is in the tree when the queue holds '
            'three faces',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayFaceKey(0, 6),
        'K2: die 0 draws face 6, game-roll-tray-face-0-6',
      );
      _expectChild(
        tester,
        trayDieKey(1),
        trayFaceKey(1, 6),
        'K2: die 1 draws face 6, game-roll-tray-face-1-6',
      );
      _expectChild(
        tester,
        trayDieKey(2),
        trayFaceKey(2, 3),
        'K2: die 2 draws face 3, game-roll-tray-face-2-3',
      );
      for (int i = 0; i < 3; i++) {
        expect(
          find.byKey(traySelectedKey(i)),
          findsNothing,
          reason:
              'D6: the tray draws no selected mark, game-roll-tray-selected-$i',
        );
        expect(find.byKey(trayDeadKey(i)), findsNothing);
      }
      expect(
        find.byKey(bigFaceKey(turn.value!)),
        findsOneWidget,
        reason:
            'D7: the big die shows turn.value ${turn.value}, '
            'game-die-face-${turn.value}, and the tray does not reuse that key',
      );
      expect(
        find.byKey(bigFaceKey(6)),
        findsNothing,
        reason: 'D7: the big die no longer shows the first queued 6',
      );

      final Rect die = tester.getRect(find.byKey(bigDieKey));
      final Rect tray = tester.getRect(find.byKey(rollTrayKey));
      expect(
        tray.center.dx,
        greaterThan(die.center.dx),
        reason: 'K1: in en the tray sits after the big die',
      );
      expect(
        (tray.center.dy - die.center.dy).abs(),
        lessThan(36),
        reason: 'K1: the tray stays on the big die\'s row',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'case 2: the rings are the union over every alive face and a tray tap '
    'changes nothing',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(
          seat: 0,
          phase: 'await_roll',
          k: 0,
          queue: const <int>[],
        ),
        seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
      );
      try {
        await mountGame(tester, drive);
        await _pushSixSixThree(tester, drive);

        for (int token = 0; token < 4; token++) {
          expect(
            find.byKey(legalRingKey(0, token)),
            findsOneWidget,
            reason: 'D1: token $token is ringed by face 6 or face 3',
          );
        }

        final int sentBefore = drive.transport.sentRaw.length;
        final int cuesBefore = drive.feedback.recorded.length;
        for (final int tile in <int>[2, 0]) {
          expect(
            find.byKey(trayDieKey(tile)),
            findsOneWidget,
            reason: 'K2: game-roll-tray-die-$tile is in the tray',
          );
          await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(tile))));
          await tester.pump();

          expect(
            drive.transport.sentRaw.length,
            sentBefore,
            reason: 'D6: tapping tray tile $tile sends nothing',
          );
          expect(
            drive.feedback.recorded.length,
            cuesBefore,
            reason: 'D6: tapping tray tile $tile plays no cue',
          );
          for (int token = 0; token < 4; token++) {
            expect(
              find.byKey(legalRingKey(0, token)),
              findsOneWidget,
              reason: 'D1/D6: the tray tap $tile leaves token $token ringed',
            );
          }
          for (int i = 0; i < 3; i++) {
            expect(find.byKey(traySelectedKey(i)), findsNothing);
          }
          expect(
            find.byKey(bigFaceKey(3)),
            findsOneWidget,
            reason: 'D7: the big die keeps turn.value 3 after a tray tap',
          );
        }
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('case 3: tapping a two-face token and then its face-3 option '
      'sends that token and that face', (tester) async {
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
    );
    try {
      await mountGame(tester, drive);
      await _pushSixSixThree(tester, drive);

      final int sentBefore = drive.transport.sentRaw.length;
      await tester.tap(find.byKey(tokenHitKey(0, 0)), warnIfMissed: false);
      await tester.pump();
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        movesSince(drive.transport, sentBefore),
        isEmpty,
        reason:
            'D2.2: token 0 is legal for 6 and for 3, so the tap opens the '
            'picker and sends nothing',
      );
      expect(
        find.byKey(facePickerKey),
        findsOneWidget,
        reason: 'D2.2: board-face-picker opens on token 0',
      );
      expect(
        find.byKey(facePickerOptionKey(3)),
        findsOneWidget,
        reason:
            'D5: board-face-picker-option-3 is the face the old tray die '
            '2 stood for',
      );

      await tester.tap(find.byKey(facePickerOptionKey(3)));
      await tester.pump();

      final List<Map<String, Object?>> moves = movesSince(
        drive.transport,
        sentBefore,
      );
      expect(
        moves,
        hasLength(1),
        reason: 'D3: the option tap sends one move; got ${moves.length}',
      );
      expect(moves.single['token'], 0, reason: 'D3: the move names token 0');
      expect(
        moves.single['face'],
        3,
        reason:
            'D3: the move names the picked face 3, not the default face '
            'and not an omitted face',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'case 4: tapping a dead tray tile sends nothing and plays no cue',
    (tester) async {
      final RollTrayDrive drive = await _mountQueue(
        tester,
        seats: twoSeats(),
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 2,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 2],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 1, 2, 3]),
          ],
        ),
      );
      try {
        expect(
          drive.controller.room!.turn!.legalByFace!.length,
          1,
          reason: 'fixture is broken: face 2 is absent from legal_by_face',
        );
        expect(
          find.byKey(trayDeadKey(1)),
          findsOneWidget,
          reason: 'K3: game-roll-tray-dead-1 marks the dead 2',
        );
        expect(find.byKey(traySelectedKey(1)), findsNothing);

        final int sentBefore = drive.transport.sentRaw.length;
        final int cuesBefore = drive.feedback.recorded.length;
        await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(1))));
        await tester.pump();

        expect(
          drive.transport.sentRaw.length,
          sentBefore,
          reason: 'D6: tapping a dead tray tile sends nothing',
        );
        expect(
          drive.feedback.recorded.skip(cuesBefore).toList(),
          isEmpty,
          reason:
              'D6: the tray is a record, so a dead tile plays no cue, '
              'not even invalidTap',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('case 5: a shorter queue on the next turn shows the new value, '
      'rings the new union and keeps no tray selection', (tester) async {
    final RollTrayDrive drive = await _mountQueue(
      tester,
      seats: twoSeats(mine: const <int>[0, 8, 16, 24]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 3,
        value: 6,
        legal: const <int>[0, 1],
        queue: const <int>[6, 5, 4],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1]),
          faceLegal(5, const <int>[2]),
          faceLegal(4, const <int>[3]),
        ],
      ),
    );
    try {
      for (int token = 0; token < 4; token++) {
        expect(
          find.byKey(legalRingKey(0, token)),
          findsOneWidget,
          reason: 'D1: token $token is ringed by one of the faces 6, 5 and 4',
        );
      }
      expect(
        find.byKey(trayDieKey(1)),
        findsOneWidget,
        reason: 'K2: game-roll-tray-die-1 is the live 5',
      );
      final int sentBefore = drive.transport.sentRaw.length;
      await tester.tapAt(tester.getCenter(find.byKey(trayDieKey(1))));
      await tester.pump();
      expect(
        drive.transport.sentRaw.length,
        sentBefore,
        reason: 'D6: tapping the 5 in the tray sends nothing',
      );
      expect(
        find.byKey(traySelectedKey(1)),
        findsNothing,
        reason: 'D6: tapping the 5 in the tray marks nothing selected',
      );

      await drive.push(tester, 'moved', <String, Object?>{
        'seat': 0,
        'token': 3,
        'from': 24,
        'to': 28,
        'captured': <Object?>[],
        'extra_roll': false,
        'face': 4,
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[6, 5],
        'value': 6,
        'legal': <int>[0, 1],
        'legal_by_face': <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1]),
          faceLegal(5, const <int>[2]),
        ],
      });

      final TurnState turn = drive.controller.room!.turn!;
      expect(turn.queue, <int>[6, 5], reason: 'fixture is broken');
      expect(turn.value, 6, reason: 'fixture is broken');
      for (int i = 0; i < 3; i++) {
        expect(
          find.byKey(traySelectedKey(i)),
          findsNothing,
          reason: 'D6: no tray tile carries a selected mark, tile $i',
        );
      }
      expect(
        find.byKey(bigFaceKey(6)),
        findsOneWidget,
        reason: 'D7: the big die shows the new turn.value, game-die-face-6',
      );
      expect(
        find.byKey(legalRingKey(0, 2)),
        findsOneWidget,
        reason: 'D1: token 2 is still ringed, by the 5',
      );
      expect(find.byKey(legalRingKey(0, 0)), findsOneWidget);
      expect(find.byKey(legalRingKey(0, 1)), findsOneWidget);
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 6: a move that leaves only dead faces shows them and plays '
      'no_move once', (tester) async {
    final RollTrayDrive drive = await _mountQueue(
      tester,
      seats: twoSeats(mine: const <int>[10, -1, -1, -1]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 3,
        value: 2,
        legal: const <int>[0],
        queue: const <int>[3, 2, 1],
        legalByFace: <Map<String, Object?>>[
          faceLegal(2, const <int>[0]),
        ],
      ),
    );
    try {
      expect(drive.controller.room!.turn!.queue, <int>[
        3,
        2,
        1,
      ], reason: 'fixture is broken');
      expect(cueCount(drive.feedback, FeedbackCue.noMove), 0);

      await drive.push(tester, 'moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 10,
        'to': 12,
        'captured': <Object?>[],
        'extra_roll': false,
        'face': 2,
      });
      await drive.push(tester, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 1,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[],
      });

      expect(drive.controller.room!.turn!.seat, 1, reason: 'fixture is broken');
      expect(
        find.byKey(noMoveMarkKey),
        findsOneWidget,
        reason:
            'K9: game-die-no-move-mark stays up for the dead faces '
            'left after the move',
      );
      expect(
        find.byKey(bigFaceKey(1)),
        findsOneWidget,
        reason: 'K9: the big die shows the last face of the dead queue',
      );
      expect(
        find.byKey(noMoveNoticeKey),
        findsOneWidget,
        reason: 'K9: the no-move line is up with the mark',
      );
      expect(
        find.byKey(rollTrayKey),
        findsOneWidget,
        reason: 'K9: the tray shows the two unspent faces',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayFaceKey(0, 3),
        'K9: the first unspent face is the 3',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayDeadKey(0),
        'K9: game-roll-tray-dead-0 marks the 3',
      );
      _expectChild(
        tester,
        trayDieKey(1),
        trayFaceKey(1, 1),
        'K9: the last unspent face is the 1',
      );
      _expectChild(
        tester,
        trayDieKey(1),
        trayDeadKey(1),
        'K9: game-roll-tray-dead-1 marks the 1',
      );
      expect(find.byKey(trayDieKey(2)), findsNothing);
      expect(
        cueCount(drive.feedback, FeedbackCue.noMove),
        1,
        reason: 'K9: the no_move cue is played once',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 7: three sixes shows the two queued sixes dead and never '
      'three tray dice', (tester) async {
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(),
    );
    try {
      await mountGame(tester, drive);
      await _pushQueuedSix(tester, drive, const <int>[6], 1);
      expect(
        trayDieCount(tester),
        lessThan(3),
        reason: 'K9: the tray never holds three dice',
      );
      await _pushQueuedSix(tester, drive, const <int>[6, 6], 2);
      expect(
        trayDieCount(tester),
        lessThan(3),
        reason: 'K9: the tray never holds three dice',
      );

      await drive.push(tester, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 3,
        'reveal': rollTrayReveal,
        'queue': <int>[],
      });
      await drive.push(tester, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'three_sixes',
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 1,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[],
      });

      expect(drive.controller.room!.turn!.seat, 1, reason: 'fixture is broken');
      expect(
        find.byKey(trayDieKey(0)),
        findsOneWidget,
        reason: 'K9: the tray keeps the first queued 6',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayFaceKey(0, 6),
        'K9: die 0 is a 6',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayDeadKey(0),
        'K9: game-roll-tray-dead-0 marks the first 6',
      );
      expect(
        find.byKey(trayDieKey(1)),
        findsOneWidget,
        reason: 'K9: the tray keeps the second queued 6',
      );
      _expectChild(
        tester,
        trayDieKey(1),
        trayFaceKey(1, 6),
        'K9: die 1 is a 6',
      );
      _expectChild(
        tester,
        trayDieKey(1),
        trayDeadKey(1),
        'K9: game-roll-tray-dead-1 marks the second 6',
      );
      expect(
        find.byKey(trayDieKey(2)),
        findsNothing,
        reason: 'K9: the third 6 is not a tray die',
      );
      expect(
        trayDieCount(tester),
        2,
        reason: 'K9: the tray holds the two queued sixes, not three',
      );
      expect(
        find.byKey(noMoveMarkKey),
        findsOneWidget,
        reason: 'K9: the three-sixes beat keeps game-die-no-move-mark',
      );
      expect(
        find.byKey(bigFaceKey(6)),
        findsOneWidget,
        reason: 'K9: the big die shows the voiding six',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 8: a six that owes another roll sits in the tray and the '
      'big die stays enabled', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(),
    );
    try {
      await mountGame(tester, drive);
      await drive.push(tester, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 1,
        'reveal': rollTrayReveal,
        'queue': <int>[6],
      });
      await drive.push(tester, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[6],
      });

      final TurnState turn = drive.controller.room!.turn!;
      expect(turn.phase, TurnPhase.awaitRoll, reason: 'fixture is broken');
      expect(turn.queue, <int>[6], reason: 'fixture is broken');
      expect(turn.seat, 0, reason: 'fixture is broken');

      expect(
        find.byKey(rollTrayKey),
        findsOneWidget,
        reason: 'K1: the tray is up while a 6 owes another roll',
      );
      _expectChild(
        tester,
        trayDieKey(0),
        trayFaceKey(0, 6),
        'K10: the tray holds the 6',
      );
      expect(
        find.byKey(traySelectedKey(0)),
        findsNothing,
        reason: 'D6: awaitRoll marks no tray tile selected',
      );
      expect(
        find.byKey(trayDeadKey(0)),
        findsNothing,
        reason: 'K3: awaitRoll marks no tray die dead',
      );
      final SemanticsNode die = tester.getSemantics(find.byKey(bigDieKey));
      expect(
        die.flagsCollection.isEnabled,
        Tristate.isTrue,
        reason: 'K10: the big die is enabled for the owed roll',
      );
      expect(
        cueCount(drive.feedback, FeedbackCue.yourTurn),
        greaterThan(0),
        reason: 'K10: the same-seat turn plays the extra-roll cue',
      );
    } finally {
      semantics.dispose();
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 9: two faces with one token each do not auto-move', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mountQueue(
      tester,
      seats: twoSeats(mine: const <int>[0, 4, -1, -1]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 2,
        value: 6,
        legal: const <int>[0],
        queue: const <int>[6, 3],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0]),
          faceLegal(3, const <int>[1]),
        ],
      ),
    );
    try {
      final TurnState turn = drive.controller.room!.turn!;
      expect(turn.legalByFace!.length, 2, reason: 'fixture is broken');
      expect(turn.legal, <int>[0], reason: 'fixture is broken');
      expect(find.byKey(boardKey), findsOneWidget, reason: 'fixture is broken');

      final int sentBefore = drive.transport.sentRaw.length;
      await tester.pump(const Duration(seconds: 2));
      expect(
        movesSince(drive.transport, sentBefore),
        isEmpty,
        reason:
            'K8: two faces with one token each must not send a move '
            'after 2s; sent ${movesSince(drive.transport, sentBefore)}',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 10: another seat\'s tray ignores taps', (tester) async {
    final RollTrayDrive drive = await _mountQueue(
      tester,
      turn: turnJson(
        seat: 1,
        phase: 'await_move',
        k: 2,
        value: 6,
        legal: const <int>[0],
        queue: const <int>[6, 4],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0]),
          faceLegal(4, const <int>[1]),
        ],
      ),
    );
    try {
      expect(drive.controller.room!.turn!.seat, 1, reason: 'fixture is broken');
      expect(
        find.byKey(rollTrayKey),
        findsOneWidget,
        reason: 'K1: every player sees the turn seat\'s tray',
      );
      final int sentBefore = drive.transport.sentRaw.length;
      final List<FeedbackCue> cuesBefore = List<FeedbackCue>.of(
        drive.feedback.recorded,
      );
      await tester.tap(find.byKey(trayDieKey(0)));
      await tester.pump();
      expect(
        drive.transport.sentRaw.length,
        sentBefore,
        reason: 'K5: tapping another seat\'s tray sends nothing',
      );
      expect(
        drive.feedback.recorded,
        cuesBefore,
        reason: 'K5: tapping another seat\'s tray plays no cue',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'case 11: an old server shows no tray and the move carries no face',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(seat: 0, phase: 'await_roll', k: 0),
        seats: twoSeats(mine: const <int>[3, 10, 20, 30]),
      );
      try {
        await mountGame(tester, drive);
        await drive.push(tester, 'rolled', <String, Object?>{
          'seat': 0,
          'value': 4,
          'legal': <int>[0],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 1,
          'reveal': rollTrayReveal,
        });

        final TurnState turn = drive.controller.room!.turn!;
        expect(turn.phase, TurnPhase.awaitMove, reason: 'fixture is broken');
        expect(turn.queue, isEmpty, reason: 'fixture is broken');
        expect(turn.legalByFace, isNull, reason: 'fixture is broken');
        expect(turn.value, 4, reason: 'fixture is broken');
        expect(
          find.byKey(legalRingKey(0, 0)),
          findsOneWidget,
          reason: 'fixture is broken: token 0 is ringed',
        );

        expect(
          find.byKey(rollTrayKey),
          findsNothing,
          reason: 'K1: an old server, with no queue, shows no tray',
        );
        final int sentBefore = drive.transport.sentRaw.length;
        await tester.tap(find.byKey(tokenHitKey(0, 0)));
        await tester.pump();

        final List<Map<String, Object?>> moves = movesSince(
          drive.transport,
          sentBefore,
        );
        expect(
          moves,
          hasLength(1),
          reason: 'fixture is broken: the tap sends a move',
        );
        expect(moves.single['token'], 0);
        expect(
          moves.single.containsKey('face'),
          isFalse,
          reason: 'K6: a move to an old server has no face key',
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('case 12: en tray semantics labels', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(),
    );
    try {
      await mountGame(tester, drive, locale: const Locale('en'));
      await _pushQueuedSix(tester, drive, const <int>[6], 1);
      _expectTrayLabel(tester, 0, 'Die 6', 'D6: awaitRoll label is "Die 6"');
      _expectHitTarget(tester, trayDieKey(0));

      await _pushQueuedSix(tester, drive, const <int>[6, 6], 2);
      await drive.push(tester, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 2,
        'legal': <int>[0, 1, 2, 3],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 3,
        'reveal': rollTrayReveal,
        'queue': <int>[6, 6, 2],
        'legal_by_face': <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
        ],
      });

      _expectTrayLabel(
        tester,
        0,
        'Die 6, can move',
        'D6: every alive 6 reads "Die 6, can move", none "selected"',
      );
      _expectTrayLabel(
        tester,
        1,
        'Die 6, can move',
        'D6: the other live 6 reads "Die 6, can move"',
      );
      _expectTrayLabel(
        tester,
        2,
        'Die 2, no move',
        'D6: the dead 2 reads "Die 2, no move"',
      );
      _expectHitTarget(tester, trayDieKey(0));
      _expectHitTarget(tester, trayDieKey(1));
      _expectHitTarget(tester, trayDieKey(2));
    } finally {
      semantics.dispose();
      await releaseGame(tester, drive);
    }
  });

  testWidgets('case 12: ar tray semantics labels', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(),
    );
    try {
      await mountGame(tester, drive, locale: const Locale('ar'));
      await _pushQueuedSix(tester, drive, const <int>[6], 1);
      _expectTrayLabel(
        tester,
        0,
        'النرد 6',
        'D6: awaitRoll label is "النرد 6"',
      );

      await _pushQueuedSix(tester, drive, const <int>[6, 6], 2);
      await drive.push(tester, 'rolled', <String, Object?>{
        'seat': 0,
        'value': 2,
        'legal': <int>[0, 1, 2, 3],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 3,
        'reveal': rollTrayReveal,
        'queue': <int>[6, 6, 2],
        'legal_by_face': <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
        ],
      });

      _expectTrayLabel(
        tester,
        0,
        'النرد 6، يمكن التحريك',
        'D6: every alive 6 reads "النرد 6، يمكن التحريك", none "محدد"',
      );
      _expectTrayLabel(
        tester,
        1,
        'النرد 6، يمكن التحريك',
        'D6: the other live 6 reads "النرد 6، يمكن التحريك"',
      );
      _expectTrayLabel(
        tester,
        2,
        'النرد 2، لا حركة',
        'D6: the dead 2 reads "النرد 2، لا حركة"',
      );
    } finally {
      semantics.dispose();
      await releaseGame(tester, drive);
    }
  });
}

void _expectTrayLabel(
  WidgetTester tester,
  int index,
  String label,
  String reason,
) {
  expect(find.byKey(trayDieKey(index)), findsOneWidget, reason: reason);
  final SemanticsNode node = tester.getSemantics(find.byKey(trayDieKey(index)));
  expect(node.label, label, reason: reason);
  expect(
    node.flagsCollection.isButton,
    isFalse,
    reason: 'D6: tray tile $index ("${node.label}") is not a button',
  );
  expect(
    node.getSemanticsData().hasAction(SemanticsAction.tap),
    isFalse,
    reason: 'D6: tray tile $index ("${node.label}") exposes no tap action',
  );
}

void _expectHitTarget(WidgetTester tester, Key key) {
  final Size size = tester.getSize(find.byKey(key));
  expect(
    size.width,
    greaterThanOrEqualTo(48),
    reason: 'K11: $key is at least 48dp wide',
  );
  expect(
    size.height,
    greaterThanOrEqualTo(48),
    reason: 'K11: $key is at least 48dp tall',
  );
}
