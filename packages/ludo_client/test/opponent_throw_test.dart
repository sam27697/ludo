// Widget acceptance proof for the opponent's 3D thrown die (order 377,
// contract C-377 A2-A6). Driven through a real GameScreen on RoomController
// and FakeTransport via roll_tray_harness.dart.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_cube.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/roll_tray_harness.dart';

const Duration _kFrame = Duration(milliseconds: 16);

const Key _ludoBoardKey = Key('ludo-board');
const Key _dieCubeKey = Key('die-cube');
const Key _idleArtKey = Key('game-die-idle-art');
const Key _tumblingDieKey = Key('game-die-tumbling');

Key _opponentThrowKey(int seat) => Key('opponent-throw-$seat');

Key _opponentThrowTumblingKey(int seat) => Key('opponent-throw-tumbling-$seat');

Key _opponentThrowLandedKey(int seat, int face) =>
    Key('opponent-throw-landed-$seat-$face');

List<Map<String, Object?>> _seatsZeroAndTwo({
  List<int> mine = const <int>[-1, -1, -1, -1],
  List<int> opponent = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  seatJson(0, name: 'Sam', tokens: mine),
  seatJson(2, name: 'Bob', tokens: opponent),
];

Map<String, Object?> _roomSnapshotData({
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
  int seq = 1,
}) => <String, Object?>{
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
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

Future<void> _mountReducedMotionGame(
  WidgetTester tester,
  RollTrayDrive drive,
) async {
  await tester.pumpWidget(
    rollTrayHarness(
      Builder(
        builder: (BuildContext context) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: FeedbackScope(
              settings: FeedbackSettings.forTest(),
              service: drive.feedback,
              child: GameScreen(controller: drive.controller),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Advances [duration] in 16 ms frame steps without rounding overrun.
Future<void> _pumpDuration(WidgetTester tester, Duration duration) async {
  Duration elapsed = Duration.zero;
  while (elapsed < duration) {
    final Duration remaining = duration - elapsed;
    final Duration step = remaining < _kFrame ? remaining : _kFrame;
    await tester.pump(step);
    elapsed += step;
  }
}

void _expectNoOpponentThrowKeys(WidgetTester tester) {
  for (final int seat in const <int>[0, 1, 2, 3]) {
    expect(find.byKey(_opponentThrowKey(seat)), findsNothing);
    expect(find.byKey(_opponentThrowTumblingKey(seat)), findsNothing);
    for (int face = 1; face <= 6; face++) {
      expect(find.byKey(_opponentThrowLandedKey(seat, face)), findsNothing);
    }
  }
}

void main() {
  for (int v = 1; v <= 6; v++) {
    testWidgets(
      'A2: seat 2 rolled face $v tumbles on board, lands on seat 2\'s yard '
      'centre in the top-right quarter, leaves the below-board die mine and '
      'idle, and fades with no feedback cue',
      (tester) async {
        final RollTrayDrive drive = await connectPlaying(
          tester,
          turn: turnJson(seat: 2, phase: 'await_roll', k: 0),
          seats: _seatsZeroAndTwo(opponent: const <int>[0, -1, -1, -1]),
        );
        try {
          await mountGame(tester, drive);
          _expectNoOpponentThrowKeys(tester);

          final List<FeedbackCue> cuesBefore = List<FeedbackCue>.of(
            drive.feedback.recorded,
          );

          await drive.push(tester, 'rolled', <String, Object?>{
            'seat': 2,
            'value': v,
            'legal': <int>[0],
            'deadline_ms': rollTrayDeadlineMs,
            'k': 1,
            'reveal': rollTrayReveal,
          });

          final Rect boardRect = tester.getRect(find.byKey(_ludoBoardKey));
          expect(
            find.byKey(_opponentThrowKey(2)),
            findsOneWidget,
            reason: 'A2: opponent-throw-2 is present right after trigger',
          );
          expect(
            find.byKey(_opponentThrowTumblingKey(2)),
            findsOneWidget,
            reason: 'A2: opponent-throw-tumbling-2 shows while travelling',
          );
          expect(
            find.byKey(_opponentThrowLandedKey(2, v)),
            findsNothing,
            reason: 'A2: landed key is not shown while still tumbling',
          );
          expect(
            find.byKey(_dieCubeKey),
            findsWidgets,
            reason: 'A2: DieCube is rendered for the thrown die',
          );
          final Rect throwRect = tester.getRect(
            find.byKey(_opponentThrowKey(2)),
          );
          expect(
            boardRect.contains(throwRect.center),
            isTrue,
            reason: 'A2: thrown die sits inside the ludo-board rect',
          );
          expect(
            find.byKey(_idleArtKey),
            findsOneWidget,
            reason:
                'A2/D2: below-board GameDie shows game-die-idle-art while '
                'opponent throw is in flight',
          );
          expect(
            find.byKey(bigFaceKey(v)),
            findsNothing,
            reason:
                'A2/D2: below-board GameDie does not give away face $v '
                'before the throw lands',
          );

          await _pumpDuration(tester, kThrowTumble);
          await tester.pump(_kFrame);

          expect(
            find.byKey(_opponentThrowKey(2)),
            findsOneWidget,
            reason: 'A2: opponent-throw-2 stays present during rest',
          );
          expect(
            find.byKey(_opponentThrowTumblingKey(2)),
            findsNothing,
            reason: 'A2: opponent-throw-tumbling-2 is gone once landed',
          );
          expect(
            find.byKey(_opponentThrowLandedKey(2, v)),
            findsOneWidget,
            reason:
                'A2: opponent-throw-landed-2-$v is present by '
                'kThrowTumble + one frame',
          );

          final Rect landedRect = tester.getRect(
            find.byKey(_opponentThrowLandedKey(2, v)),
          );
          final Offset landedCenter = landedRect.center;
          expect(
            landedCenter.dx,
            greaterThan(boardRect.center.dx),
            reason: 'A2: landed centre is in the right half of ludo-board',
          );
          expect(
            landedCenter.dx,
            lessThan(boardRect.right),
            reason: 'A2: landed centre is inside the right edge of ludo-board',
          );
          expect(
            landedCenter.dy,
            greaterThan(boardRect.top),
            reason: 'A2: landed centre is inside the top edge of ludo-board',
          );
          expect(
            landedCenter.dy,
            lessThan(boardRect.center.dy),
            reason: 'A2: landed centre is in the top half of ludo-board',
          );

          // C-465 D3.1: the throw lands on the centre of seat 2's yard
          // quadrant (my yard is bottom-left, so seat 2 is top-right).
          final Rect yard = yardQuadrantViewRect(boardSquare(tester), 2, 0);
          expect(
            (landedCenter - yard.center).distance,
            lessThan(1.0),
            reason:
                'C-465 D3: landed centre $landedCenter is on seat 2\'s yard '
                'centre ${yard.center}',
          );
          // C-465 D1.2 replaces "the big die takes the face once landed":
          // the die under the board is mine and never shows seat 2's face.
          expect(
            find.byKey(bigFaceKey(v)),
            findsNothing,
            reason:
                'C-465 D1: below-board GameDie never shows seat 2\'s face '
                '$v, landed or not',
          );
          expect(
            find.byKey(_idleArtKey),
            findsOneWidget,
            reason:
                'C-465 D1: game-die-idle-art stays on the die under the board',
          );
          expect(
            find.byKey(seatDieFaceKey(2, v)),
            findsOneWidget,
            reason: 'C-465 D2: seat 2\'s own die shows face $v under the throw',
          );
          expect(
            drive.feedback.recorded,
            cuesBefore,
            reason: 'A2/D9: no feedback cue fires for another seat\'s throw',
          );

          await _pumpDuration(tester, kThrowRest);
          await tester.pump(_kFrame);
          await _pumpDuration(tester, kThrowFade);

          _expectNoOpponentThrowKeys(tester);
          expect(
            drive.feedback.recorded,
            cuesBefore,
            reason: 'A2/D9: no feedback cue fires after throw finishes',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'A3: two back-to-back rolled frames for seat 2 (6 then 3) land in order '
    'and finish within 2x kThrowFast + kThrowTumble + kThrowRest + kThrowFade',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(
          seat: 2,
          phase: 'await_roll',
          k: 0,
          queue: const <int>[],
        ),
        seats: _seatsZeroAndTwo(opponent: const <int>[0, -1, -1, -1]),
      );
      try {
        await mountGame(tester, drive);

        await drive.push(tester, 'rolled', <String, Object?>{
          'seat': 2,
          'value': 6,
          'legal': <int>[],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 1,
          'reveal': rollTrayReveal,
          'queue': <int>[6],
        });
        await drive.push(tester, 'rolled', <String, Object?>{
          'seat': 2,
          'value': 3,
          'legal': <int>[0],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 2,
          'reveal': rollTrayReveal,
          'queue': <int>[6, 3],
          'legal_by_face': <Map<String, Object?>>[
            faceLegal(6, const <int>[0]),
            faceLegal(3, const <int>[0]),
          ],
        });

        // First throw is fast-forwarded to kThrowFast tumble and kThrowFast
        // rest because the second throw is queued behind it.
        await _pumpDuration(tester, kThrowFast);
        await tester.pump(_kFrame);

        expect(
          find.byKey(_opponentThrowLandedKey(2, 6)),
          findsOneWidget,
          reason: 'A3: landed-2-6 is seen first after kThrowFast tumble',
        );
        expect(
          find.byKey(_opponentThrowLandedKey(2, 3)),
          findsNothing,
          reason: 'A3: landed-2-3 is not yet shown while 6 is resting',
        );

        // First throw finishes its kThrowFast rest; second throw tumbles for
        // kThrowTumble and lands on 3.
        await _pumpDuration(tester, kThrowFast);
        await tester.pump(_kFrame);
        await _pumpDuration(tester, kThrowTumble);
        await tester.pump(_kFrame);

        expect(
          find.byKey(_opponentThrowLandedKey(2, 3)),
          findsOneWidget,
          reason: 'A3: landed-2-3 is seen after landed-2-6',
        );
        expect(
          find.byKey(_opponentThrowLandedKey(2, 6)),
          findsNothing,
          reason: 'A3: landed-2-6 is gone once throw 2 has taken over',
        );

        // Second throw rests kThrowRest and fades kThrowFade.
        await _pumpDuration(tester, kThrowRest);
        await tester.pump(_kFrame);
        await _pumpDuration(tester, kThrowFade);

        _expectNoOpponentThrowKeys(tester);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A4: my own roll shows die-cube under game-die-tumbling while in flight '
    'and never builds an opponent-throw key',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(seat: 0, phase: 'await_roll', k: 0),
        seats: _seatsZeroAndTwo(mine: const <int>[0, 10, -1, -1]),
      );
      try {
        await mountGame(tester, drive);
        _expectNoOpponentThrowKeys(tester);

        await tester.tap(find.byKey(bigDieKey));
        await tester.pump();

        expect(
          find.byKey(_tumblingDieKey),
          findsOneWidget,
          reason: 'A4: game-die-tumbling is present while my roll is in flight',
        );
        expect(
          find.descendant(
            of: find.byKey(_tumblingDieKey),
            matching: find.byKey(_dieCubeKey),
          ),
          findsOneWidget,
          reason: 'A4: die-cube is rendered under game-die-tumbling',
        );
        _expectNoOpponentThrowKeys(tester);

        await _pumpDuration(tester, kThrowFast);
        expect(
          find.descendant(
            of: find.byKey(_tumblingDieKey),
            matching: find.byKey(_dieCubeKey),
          ),
          findsOneWidget,
          reason: 'A4: die-cube stays under game-die-tumbling mid-flight',
        );
        _expectNoOpponentThrowKeys(tester);

        await drive.push(tester, 'rolled', <String, Object?>{
          'seat': 0,
          'value': 4,
          'legal': <int>[0, 1],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 1,
          'reveal': rollTrayReveal,
        });

        expect(
          find.byKey(_tumblingDieKey),
          findsNothing,
          reason: 'A4/D7: tumble stops when my rolled frame arrives',
        );
        expect(
          find.byKey(bigFaceKey(4)),
          findsOneWidget,
          reason: 'A4/D7: below-board die lands on turn.value',
        );
        _expectNoOpponentThrowKeys(tester);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A5: under reduced motion, landed key appears on first frame, tumbling '
    'key never appears, and throw is gone after kThrowRest + one frame',
    (tester) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(seat: 2, phase: 'await_roll', k: 0),
        seats: _seatsZeroAndTwo(opponent: const <int>[0, -1, -1, -1]),
      );
      try {
        await _mountReducedMotionGame(tester, drive);
        _expectNoOpponentThrowKeys(tester);

        await drive.push(tester, 'rolled', <String, Object?>{
          'seat': 2,
          'value': 5,
          'legal': <int>[0],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 1,
          'reveal': rollTrayReveal,
        });

        final Rect boardRect = tester.getRect(find.byKey(_ludoBoardKey));
        expect(
          find.byKey(_opponentThrowKey(2)),
          findsOneWidget,
          reason: 'A5: opponent-throw-2 is present on the first frame',
        );
        expect(
          find.byKey(_opponentThrowLandedKey(2, 5)),
          findsOneWidget,
          reason:
              'A5: opponent-throw-landed-2-5 is present on the first frame '
              'after the trigger under reduced motion',
        );
        expect(
          find.byKey(_opponentThrowTumblingKey(2)),
          findsNothing,
          reason: 'A5: opponent-throw-tumbling-2 never appears',
        );

        final Rect landedRect = tester.getRect(
          find.byKey(_opponentThrowLandedKey(2, 5)),
        );
        final Offset landedCenter = landedRect.center;
        expect(landedCenter.dx, greaterThan(boardRect.center.dx));
        expect(landedCenter.dx, lessThan(boardRect.right));
        expect(landedCenter.dy, greaterThan(boardRect.top));
        expect(landedCenter.dy, lessThan(boardRect.center.dy));

        Duration elapsed = Duration.zero;
        final Duration total = kThrowRest + _kFrame;
        while (elapsed < total) {
          final Duration remaining = total - elapsed;
          final Duration step = remaining < _kFrame ? remaining : _kFrame;
          await tester.pump(step);
          elapsed += step;
          expect(
            find.byKey(_opponentThrowTumblingKey(2)),
            findsNothing,
            reason: 'A5: opponent-throw-tumbling-2 never appears in any frame',
          );
        }

        _expectNoOpponentThrowKeys(tester);
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'A6: a resync snapshot carrying a turn for seat 2 already rolled shows '
    'no opponent-throw-2 in any pumped frame',
    (tester) async {
      final List<Map<String, Object?>> seats = _seatsZeroAndTwo(
        opponent: const <int>[0, -1, -1, -1],
      );
      final RollTrayDrive drive = await connectPlaying(
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
        seats: seats,
      );
      try {
        await mountGame(tester, drive);
        expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        for (int i = 0; i < 5; i++) {
          await tester.pump(_kFrame);
          expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        }

        // Unsolicited room snapshot push while mounted.
        await drive.push(
          tester,
          'room',
          _roomSnapshotData(
            seats: seats,
            turn: turnJson(
              seat: 2,
              phase: 'await_move',
              k: 2,
              value: 5,
              legal: const <int>[0],
              queue: const <int>[5],
              legalByFace: <Map<String, Object?>>[
                faceLegal(5, const <int>[0]),
              ],
            ),
          ),
        );
        expect(drive.controller.room!.turn!.seat, 2);
        expect(drive.controller.room!.turn!.value, 5);
        expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        for (int i = 0; i < 5; i++) {
          await tester.pump(_kFrame);
          expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        }

        // Sequence-gap resync answered with a room snapshot carrying seat 2's
        // already-rolled turn.
        drive.transport.pushText(
          jsonEncode(<String, Object?>{
            'v': 1,
            't': 'turn',
            'id': 'resync-gap-trigger',
            'd': <String, Object?>{
              'seat': 2,
              'phase': 'await_roll',
              'deadline_ms': rollTrayDeadlineMs,
              'seq': drive.lastSeq + 5,
            },
          }),
        );
        await tester.pump();
        final String resumeId =
            decodeFrame(drive.transport.sentRaw.last)['id']! as String;
        drive.lastSeq += 6;
        drive.transport.pushText(
          jsonEncode(<String, Object?>{
            'v': 1,
            't': 'room',
            'id': 'resync-room-reply',
            're': resumeId,
            'd': _roomSnapshotData(
              seats: seats,
              seq: drive.lastSeq,
              turn: turnJson(
                seat: 2,
                phase: 'await_move',
                k: 3,
                value: 6,
                legal: const <int>[0],
                queue: const <int>[6],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(6, const <int>[0]),
                ],
              ),
            ),
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(drive.controller.hasDesynced, isFalse);
        expect(drive.controller.room!.turn!.seat, 2);
        expect(drive.controller.room!.turn!.value, 6);
        expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        for (int i = 0; i < 5; i++) {
          await tester.pump(_kFrame);
          expect(find.byKey(_opponentThrowKey(2)), findsNothing);
        }
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}
