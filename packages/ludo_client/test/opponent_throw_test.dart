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

// C-667t r2: the default test surface (800x600) is a large landscape since
// C-667. The A2 cases test the thrown die, not the tablet layout, so they run
// on a phone surface. The order named P1 (360x780 portrait), but A2's first
// assertion, boardRect.contains(throwRect.center) on the ludo-board box, cannot
// hold there: the throw starts at the top-right corner of the painted square
// (measured on 4c71c0f: centre x 352.0, the right edge of a ludo-board box that
// is as wide as the square on a portrait phone), and Rect.contains excludes
// the right edge. The same cases pass on a landscape phone, where the box is
// wider than the square, so they are pinned to P1 turned on its side: 780x360
// logical at density 3.0, still a phone (shortestSide 360 < 600, contract D3).
// The twins run on T2, 1480x924 logical at density 2.0, and measure against the
// painted square, edges included.
const Size _p1Surface = Size(780, 360);
const double _p1Density = 3.0;
const Size _t2Surface = Size(1480, 924);
const double _t2Density = 2.0;

void _surface(WidgetTester tester, Size logical, double density) {
  tester.view.physicalSize = Size(
    logical.width * density,
    logical.height * density,
  );
  tester.view.devicePixelRatio = density;
  addTearDown(tester.view.reset);
}

/// C-468 D6's FeedbackCue.dieLand, looked up by name so this file still
/// compiles, and its other cases still run, on a tree where the cue does
/// not exist yet (order 469).
FeedbackCue get _dieLand => FeedbackCue.values.byName('dieLand');

void main() {
  for (int v = 1; v <= 6; v++) {
    testWidgets(
      'A2: seat 2 rolled face $v tumbles on board, lands on seat 2\'s yard '
      'centre in the top-right quarter, leaves the below-board die mine and '
      'idle, and fades with no feedback cue but the one dieLand',
      (tester) async {
        _surface(tester, _p1Surface, _p1Density);
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
          // C-468 D4.1: the landing of another seat's die is heard, once;
          // nothing else fires for the throw.
          expect(
            drive.feedback.recorded,
            <FeedbackCue>[...cuesBefore, _dieLand],
            reason:
                'A2/D9 as amended by C-468 D4: only dieLand fires for another '
                'seat\'s throw once it has landed',
          );

          await _pumpDuration(tester, kThrowRest);
          await tester.pump(_kFrame);
          await _pumpDuration(tester, kThrowFade);

          _expectNoOpponentThrowKeys(tester);
          expect(
            drive.feedback.recorded,
            <FeedbackCue>[...cuesBefore, _dieLand],
            reason:
                'A2/D9 as amended by C-468 D4: still just the one dieLand '
                'after the throw finishes',
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  // C-667t r2: the large-landscape twins of the six A2 cases (T2, contract
  // D1). Everything the A2 case asserts, with the board measured as the
  // painted square (game-screen-board centres the largest square in its box,
  // the way boardSquare in the harness reads it) instead of the ludo-board
  // box: at T2 the ludo-board box is wider than the square the board draws.
  for (int v = 1; v <= 6; v++) {
    testWidgets(
      'A2 twin T2: seat 2 rolled face $v tumbles on the board square and '
      'lands on seat 2\'s yard centre in the top-right quarter',
      (tester) async {
        _surface(tester, _t2Surface, _t2Density);
        final String where =
            'scenario: T2 1480x924 dp at density 2.0, en, seat 2 rolled $v, '
            "rerun with --plain-name 'A2 twin T2: seat 2 rolled face $v'";
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

          final Rect square = boardSquare(tester);
          final Rect ludoBox = tester.getRect(find.byKey(_ludoBoardKey));
          expect(
            find.byKey(_opponentThrowKey(2)),
            findsOneWidget,
            reason:
                'A2: opponent-throw-2 is present right after trigger. $where',
          );
          expect(
            find.byKey(_opponentThrowTumblingKey(2)),
            findsOneWidget,
            reason:
                'A2: opponent-throw-tumbling-2 shows while travelling. $where',
          );
          expect(
            find.byKey(_opponentThrowLandedKey(2, v)),
            findsNothing,
            reason: 'A2: landed key is not shown while still tumbling. $where',
          );
          final Rect throwRect = tester.getRect(
            find.byKey(_opponentThrowKey(2)),
          );
          expect(
            square.inflate(1).contains(throwRect.center),
            isTrue,
            reason:
                'A2/D1: the thrown die centre ${throwRect.center} is inside '
                'the painted board square $square (edges included, 1 dp; '
                'ludo-board box $ludoBox). '
                '$where',
          );
          expect(
            find.byKey(_idleArtKey),
            findsOneWidget,
            reason:
                'A2/D2: below-board GameDie shows game-die-idle-art while '
                'opponent throw is in flight. $where',
          );
          expect(
            find.byKey(bigFaceKey(v)),
            findsNothing,
            reason:
                'A2/D2: the die beside the board does not give away face $v '
                'before the throw lands. $where',
          );

          await _pumpDuration(tester, kThrowTumble);
          await tester.pump(_kFrame);

          expect(
            find.byKey(_opponentThrowTumblingKey(2)),
            findsNothing,
            reason: 'A2: opponent-throw-tumbling-2 is gone once landed. $where',
          );
          expect(
            find.byKey(_opponentThrowLandedKey(2, v)),
            findsOneWidget,
            reason:
                'A2: opponent-throw-landed-2-$v is present by kThrowTumble '
                '+ one frame. $where',
          );

          final Offset landedCenter = tester
              .getRect(find.byKey(_opponentThrowLandedKey(2, v)))
              .center;
          expect(
            landedCenter.dx,
            greaterThan(square.center.dx),
            reason:
                'A2: landed centre is in the right half of the square. $where',
          );
          expect(
            landedCenter.dx,
            lessThan(square.right),
            reason: 'A2: landed centre is inside the right edge. $where',
          );
          expect(
            landedCenter.dy,
            greaterThan(square.top),
            reason: 'A2: landed centre is inside the top edge. $where',
          );
          expect(
            landedCenter.dy,
            lessThan(square.center.dy),
            reason:
                'A2: landed centre is in the top half of the square. $where',
          );
          final Rect yard = yardQuadrantViewRect(square, 2, 0);
          expect(
            (landedCenter - yard.center).distance,
            lessThan(1.0),
            reason:
                'C-465 D3: landed centre $landedCenter is on seat 2\'s yard '
                'centre ${yard.center}. $where',
          );
          expect(
            find.byKey(bigFaceKey(v)),
            findsNothing,
            reason:
                'C-465 D1: my die never shows seat 2\'s face $v, landed or '
                'not. $where',
          );
          expect(
            find.byKey(_idleArtKey),
            findsOneWidget,
            reason: 'C-465 D1: game-die-idle-art stays on my die. $where',
          );
          expect(
            find.byKey(seatDieFaceKey(2, v)),
            findsOneWidget,
            reason: 'C-465 D2: seat 2\'s own die shows face $v. $where',
          );
          expect(
            drive.feedback.recorded,
            <FeedbackCue>[...cuesBefore, _dieLand],
            reason: 'A2/D9 as amended by C-468 D4: only dieLand fires. $where',
          );

          await _pumpDuration(tester, kThrowRest);
          await tester.pump(_kFrame);
          await _pumpDuration(tester, kThrowFade);

          _expectNoOpponentThrowKeys(tester);
          expect(
            drive.feedback.recorded,
            <FeedbackCue>[...cuesBefore, _dieLand],
            reason: 'A2/D9: still just the one dieLand after the throw. $where',
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
