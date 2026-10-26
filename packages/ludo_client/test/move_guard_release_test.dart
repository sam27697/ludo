// Order 383: the move guard in game_screen.dart stops a second move for a
// decision that already has one in flight. It is released only when the
// live turn stops being that decision, so a move the server refuses, or a
// move that went out on a socket that died before the server read it,
// leaves the same decision on screen with the guard still set: every tap
// and the one-legal hold send nothing, and the turn waits for the server's
// timer. docs/PROTOCOL.md section 20: after a drop the client resumes,
// reads the snapshot and acts on what it shows, and a second move for a
// decision is gated by the server, so letting the player tap again is safe.
//
// All four are red while the guard outlives its request. Case 3 also keeps
// the guard's own job: one decision, one move in flight, after a refusal
// too, so a fix that drops the guard altogether stays red there. Case 4
// keeps the one-legal hold from resending a refused move on its own.
//
// Migrated by order 463 to C-462: in cases 1 to 3 the queue is [6, 3] with
// both tokens legal for both faces, so a spend is a tap on the token and
// then on board-face-picker-option-<face>. Case 4 has one face and one
// token, so its tap still sends at once.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const Duration _frame = Duration(milliseconds: 16);

/// Taps seat 0's [token] and then its picker option for [face]: under the
/// two-face queue every token here can take either face, so each tap asks
/// (C-462 D2.2) and the pick is what sends (D3).
Future<void> _spend(WidgetTester tester, int token, {required int face}) async {
  await tester.tap(find.byKey(tokenHitKey(0, token)), warnIfMissed: false);
  await tester.pump();
  for (int i = 0; i < 12; i++) {
    await tester.pump(_frame);
  }
  expect(
    find.byKey(facePickerKey),
    findsOneWidget,
    reason:
        'C-462 D2.2: token $token can take faces 6 and 3, so the tap opens '
        'board-face-picker and sends nothing yet',
  );
  await tester.tap(find.byKey(facePickerOptionKey(face)));
  await tester.pump();
}

List<Map<String, Object?>> _seats() =>
    twoSeats(mine: const <int>[10, 20, -1, -1]);

/// My turn, await_move at k 3 with the queue [6, 3]: tokens 0 and 1 on the
/// track, both legal for either face.
Map<String, Object?> _twoFacesTurn() => turnJson(
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
);

/// My turn, await_move at k 3 with the queue [3] and one legal token, so
/// the one-legal hold arms.
Map<String, Object?> _oneLegalTurn() => turnJson(
  seat: 0,
  phase: 'await_move',
  k: 3,
  value: 3,
  legal: const <int>[0],
  queue: const <int>[3],
  legalByFace: <Map<String, Object?>>[
    faceLegal(3, const <int>[0]),
  ],
);

Future<RollTrayDrive> _mount(
  WidgetTester tester,
  Map<String, Object?> turn,
) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    seats: _seats(),
    turn: turn,
  );
  await mountGame(tester, drive);
  return drive;
}

/// The raw text of every `move` this transport sent from [from] on.
List<String> _moveFramesSince(FakeTransport transport, int from) => transport
    .sentRaw
    .skip(from)
    .where((String text) => frameType(text) == 'move')
    .toList();

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  for (int i = 0; i < total.inMilliseconds ~/ _frame.inMilliseconds; i++) {
    await tester.pump(_frame);
  }
}

void main() {
  testWidgets('a move the server refuses leaves the token tappable again', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester, _twoFacesTurn());
    try {
      final int before = drive.transport.sentRaw.length;
      await _spend(tester, 0, face: 6);
      final List<String> first = _moveFramesSince(drive.transport, before);
      expect(first, hasLength(1), reason: 'fixture: the first move is sent');

      drive.transport.pushText(
        errorReplyFrame(re: requestIdOf(first.single), code: 'ILLEGAL_MOVE'),
      );
      await tester.pump();
      await tester.pump();
      expect(
        drive.controller.phase,
        RoomPhase.connected,
        reason: 'fixture: a refused move keeps the room connected',
      );
      expect(
        drive.controller.room!.turn!.k,
        3,
        reason: 'fixture: no frame changed the decision',
      );

      final int beforeRetry = drive.transport.sentRaw.length;
      await _spend(tester, 1, face: 3);
      final List<Map<String, Object?>> retry = movesSince(
        drive.transport,
        beforeRetry,
      );
      expect(
        retry,
        hasLength(1),
        reason:
            'the server refused the first move and the decision is still on '
            'screen: the next tap must go out; got ${retry.length} moves, so '
            'the turn would wait for the server timer',
      );
      expect(retry.single['token'], 1);
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'a move lost with the socket can be made again after the resume',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester, _twoFacesTurn());
      try {
        final int before = drive.transport.sentRaw.length;
        await _spend(tester, 0, face: 6);
        expect(
          _moveFramesSince(drive.transport, before),
          hasLength(1),
          reason: 'fixture: the move went out on the first socket',
        );

        // The socket dies before the server read the move.
        drive.transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        // closed, or failed when the move still waiting on its reply is
        // what reports the dead socket; reconnect() is legal from both.
        expect(
          drive.controller.phase,
          anyOf(RoomPhase.closed, RoomPhase.failed),
          reason: 'fixture: the far side vanishing ends the connection',
        );

        final FakeTransport second = FakeTransport();
        drive.enqueueTransport(second);
        final Future<void> resumed = drive.controller.reconnect();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        expect(
          second.sentRaw.where((String t) => frameType(t) == 'resume'),
          hasLength(1),
          reason: 'fixture: reconnect sends one resume on the new socket',
        );
        final String resumeId = requestIdOf(
          second.sentRaw.lastWhere((String t) => frameType(t) == 'resume'),
        );
        // The server never saw the move: the snapshot shows the same
        // decision, k 3 with the queue [6, 3].
        second.pushText(
          roomReplyFrame(
            re: resumeId,
            seats: _seats(),
            turn: _twoFacesTurn(),
            seq: drive.lastSeq + 1,
          ),
        );
        await resumed;
        await tester.pump();
        await tester.pump();
        expect(
          drive.controller.phase,
          RoomPhase.connected,
          reason: 'fixture: the resume succeeded',
        );

        final int beforeRetry = second.sentRaw.length;
        await _spend(tester, 0, face: 6);
        final List<Map<String, Object?>> retry = movesSince(
          second,
          beforeRetry,
        );
        expect(
          retry,
          hasLength(1),
          reason:
              'after the resume the snapshot shows my decision with no move '
              'made: a tap must send it; got ${retry.length} moves',
        );
        expect(retry.single['token'], 0);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('after a refusal two quick taps still send one move', (
    tester,
  ) async {
    final RollTrayDrive drive = await _mount(tester, _twoFacesTurn());
    try {
      final int before = drive.transport.sentRaw.length;
      await _spend(tester, 0, face: 6);
      final List<String> first = _moveFramesSince(drive.transport, before);
      expect(first, hasLength(1), reason: 'fixture: the first move is sent');
      drive.transport.pushText(
        errorReplyFrame(re: requestIdOf(first.single), code: 'ILLEGAL_MOVE'),
      );
      await tester.pump();
      await tester.pump();

      final int beforeRetry = drive.transport.sentRaw.length;
      await _spend(tester, 0, face: 6);
      await _spend(tester, 1, face: 3);
      final List<Map<String, Object?>> moves = movesSince(
        drive.transport,
        beforeRetry,
      );
      expect(
        moves,
        hasLength(1),
        reason:
            'one decision, one move in flight: the second tap before any '
            'answer must not send; got ${moves.length}',
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'a refused hold does not resend by itself, and a tap sends the move',
    (tester) async {
      final RollTrayDrive drive = await _mount(tester, _oneLegalTurn());
      try {
        final int before = drive.transport.sentRaw.length;
        // The hold is 1500 ms (order 116's auto-move).
        await _pumpFor(tester, const Duration(milliseconds: 2500));
        final List<String> held = _moveFramesSince(drive.transport, before);
        expect(
          held,
          hasLength(1),
          reason: 'fixture: the one-legal hold sends the move',
        );
        drive.transport.pushText(
          errorReplyFrame(re: requestIdOf(held.single), code: 'ILLEGAL_MOVE'),
        );
        await tester.pump();
        await tester.pump();

        final int afterRefusal = drive.transport.sentRaw.length;
        await _pumpFor(tester, const Duration(milliseconds: 4000));
        expect(
          movesSince(drive.transport, afterRefusal),
          isEmpty,
          reason:
              'a refused move must not be resent by the hold on its own: '
              'that would repeat every hold period for as long as the '
              'server refuses it',
        );

        await tester.tap(find.byKey(tokenHitKey(0, 0)));
        await tester.pump();
        final List<Map<String, Object?>> tapped = movesSince(
          drive.transport,
          afterRefusal,
        );
        expect(
          tapped,
          hasLength(1),
          reason:
              'after the refusal the player may still make the move by '
              'tapping; got ${tapped.length}',
        );
        expect(tapped.single['token'], 0);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}
