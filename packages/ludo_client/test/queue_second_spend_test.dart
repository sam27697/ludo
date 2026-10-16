// Order 382: under the roll queue every face spent from one roll sequence
// belongs to the same turn.k (docs/PROTOCOL.md sections 6 and 21.3 rule 4).
// The move guard in game_screen.dart once keyed on k alone, so after the
// first spend every later tap, and the one-legal-move hold, sent nothing
// and the turn stalled until the server's timer played it. These cases pin
// the second spend, by tap and by the hold, and keep the guard's original
// job: two taps on one decision send one move.

import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

const Duration _frame = Duration(milliseconds: 16);

/// My turn, await_move at k 3 with the queue [6, 3]: tokens 0 and 1 on the
/// track, both legal for either face.
Future<RollTrayDrive> _mountTwoFaces(WidgetTester tester) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    seats: twoSeats(mine: const <int>[10, 20, -1, -1]),
    turn: turnJson(
      seat: 0,
      phase: 'await_move',
      k: 3,
      value: 6,
      legal: const <int>[0, 1],
      queue: const <int>[6, 3],
      legalByFace: <Map<String, Object?>>[
        faceLegal(6, const <int>[0, 1]),
        faceLegal(3, const <int>[0, 1]),
      ],
    ),
  );
  await mountGame(tester, drive);
  return drive;
}

/// The server's answer to spending the 6 on token 0: `moved`, then the
/// same seat's `turn` in await_move with the 3 left. No new k: none was
/// rolled.
Future<void> _answerSixOnTokenZero(
  WidgetTester tester,
  RollTrayDrive drive, {
  required List<int> legalForThree,
}) async {
  await drive.push(tester, 'moved', <String, Object?>{
    'seat': 0,
    'token': 0,
    'from': 10,
    'to': 16,
    'captured': <Object?>[],
    'extra_roll': false,
    'face': 6,
  });
  await drive.push(tester, 'turn', <String, Object?>{
    'seat': 0,
    'phase': 'await_move',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[3],
    'value': 3,
    'legal': legalForThree,
    'legal_by_face': <Map<String, Object?>>[faceLegal(3, legalForThree)],
  });
}

void main() {
  testWidgets('a second spend of the same k is sent when its token is tapped', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mountTwoFaces(tester);
    try {
      final int before = drive.transport.sentRaw.length;
      await tester.tap(find.byKey(tokenHitKey(0, 0)));
      await tester.pump();
      final List<Map<String, Object?>> first = movesSince(
        drive.transport,
        before,
      );
      expect(first, hasLength(1), reason: 'fixture: the first spend is sent');
      expect(first.single['token'], 0);
      expect(first.single['face'], 6);

      await _answerSixOnTokenZero(
        tester,
        drive,
        legalForThree: const <int>[0, 1],
      );
      expect(
        drive.controller.room!.turn!.k,
        3,
        reason: 'fixture: the turn after a spend keeps the same k',
      );
      expect(
        find.byKey(tokenHitKey(0, 1)),
        findsOneWidget,
        reason: 'fixture: token 1 must be tappable for the 3',
      );

      final int beforeSecond = drive.transport.sentRaw.length;
      await tester.tap(find.byKey(tokenHitKey(0, 1)));
      await tester.pump();
      final List<Map<String, Object?>> second = movesSince(
        drive.transport,
        beforeSecond,
      );
      expect(
        second,
        hasLength(1),
        reason:
            'the second spend of k 3 must go out; got ${second.length} '
            'moves, so the tap was dropped and the turn would stall until '
            'the server timer',
      );
      expect(second.single['token'], 1);
      expect(second.single['face'], 3);
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'the one-legal-move hold sends the last spend of the same k by itself',
    (tester) async {
      final RollTrayDrive drive = await _mountTwoFaces(tester);
      try {
        await tester.tap(find.byKey(tokenHitKey(0, 0)));
        await tester.pump();
        await _answerSixOnTokenZero(
          tester,
          drive,
          legalForThree: const <int>[0],
        );

        final int before = drive.transport.sentRaw.length;
        // The hold is 1500 ms (order 116's auto-move); 2500 ms of frames is
        // well past it and well short of the 45 s turn timer.
        for (int i = 0; i < 2500 ~/ _frame.inMilliseconds; i++) {
          await tester.pump(_frame);
        }
        final List<Map<String, Object?>> moves = movesSince(
          drive.transport,
          before,
        );
        expect(
          moves,
          hasLength(1),
          reason:
              'one legal move left for the 3: the hold must send it; got '
              '${moves.length}',
        );
        expect(moves.single['token'], 0);
        expect(moves.single['face'], 3);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('two taps before the server answers still send one move', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mountTwoFaces(tester);
    try {
      final int before = drive.transport.sentRaw.length;
      await tester.tap(find.byKey(tokenHitKey(0, 0)));
      await tester.pump();
      await tester.tap(find.byKey(tokenHitKey(0, 1)));
      await tester.pump();
      final List<Map<String, Object?>> moves = movesSince(
        drive.transport,
        before,
      );
      expect(
        moves,
        hasLength(1),
        reason:
            'one decision, one move: a second tap before `moved` arrives '
            'must not send; got ${moves.length}',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });
}
