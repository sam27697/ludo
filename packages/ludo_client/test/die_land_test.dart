// Screen proof for C-468 D4 (order 469): every die that lands is heard.
// Written from the contract's text alone. A real GameScreen over a real
// RoomController on FakeTransport, every state a decoded wire frame, the
// recording FeedbackService from support/roll_tray_harness.dart.
//
// This file does not compile on a tree without FeedbackCue.dieLand, which
// is the expected failing arm on the base.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_cube.dart';
import 'package:ludo_client/src/feedback.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

/// Everything a throw takes from the frame to the last fade pixel, plus a
/// few frames of slack.
final Duration _kThrowTotal =
    kThrowTumble + kThrowRest + kThrowFade + kC468Frame * 4;

bool _tumbling(WidgetTester tester, int seat) =>
    tester.any(find.byKey(opponentThrowTumblingKey(seat)));

bool _landed(WidgetTester tester, int seat) {
  for (int face = 1; face <= 6; face++) {
    if (tester.any(find.byKey(opponentThrowLandedKey(seat, face)))) {
      return true;
    }
  }
  return false;
}

/// Pumps frame by frame for [total] and holds the one rule D4.1 states:
/// while seat [seat]'s throw tumbles, only the throws that already left
/// their tumble have sounded. Returns how many throws left the tumble.
Future<int> _watchThrows(Scn s, int seat, Duration total) async {
  int finished = 0;
  bool wasTumbling = _tumbling(s.tester, seat);
  Duration elapsed = Duration.zero;
  while (elapsed < total) {
    await s.pump(kC468Frame);
    elapsed += kC468Frame;
    final bool tumbling = _tumbling(s.tester, seat);
    if (tumbling) {
      expect(
        s.count(FeedbackCue.dieLand),
        finished,
        reason: s.why(
          'while seat $seat\'s throw tumbles only the $finished throws that '
          'already landed have sounded (dieLand count)',
        ),
      );
    }
    if (wasTumbling && !tumbling) {
      finished += 1;
    }
    wasTumbling = tumbling;
  }
  return finished;
}

void main() {
  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    testWidgets(
      'D4.1: seat $opp\'s throw (seen from $me) plays dieLand once, not '
      'during the tumble and by the end of it, and never again for the '
      'same throw',
      (tester) async {
        final RollTrayDrive drive = await mountScreen(
          tester,
          mySeat: me,
          turn: awaitRollTurn(opp),
          seats: pairSeats(mySeat: me, mine: kYard, opponent: kYard),
        );
        final Scn s = Scn('D4.1 motion me=$me opp=$opp', tester, drive);
        try {
          expect(s.count(FeedbackCue.dieLand), 0, reason: s.why('fixture'));
          await s.push('rolled', rolledFrame(opp, 5, 1));
          expect(
            find.byKey(opponentThrowTumblingKey(opp)),
            findsOneWidget,
            reason: s.why('fixture: the throw is tumbling'),
          );
          expect(
            s.count(FeedbackCue.dieLand),
            0,
            reason: s.why('no dieLand on the frame that starts the tumble'),
          );
          final int finished = await _watchThrows(s, opp, _kThrowTotal);
          expect(finished, 1, reason: s.why('fixture: one throw landed'));
          expect(
            s.drive.feedback.recorded,
            <FeedbackCue>[FeedbackCue.dieLand],
            reason: s.why(
              'exactly one dieLand and no other cue for another seat\'s '
              'roll, even after the overlay left',
            ),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D4.1: the cue is there by the frame after the tumble ends (landed key '
    'on screen means dieLand is recorded)',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2),
        seats: pairSeats(mySeat: 0),
      );
      final Scn s = Scn('D4.1 landed key', tester, drive);
      try {
        await s.push('rolled', rolledFrame(2, 4, 1));
        int guard = 0;
        while (!_landed(tester, 2)) {
          expect(
            s.count(FeedbackCue.dieLand),
            0,
            reason: s.why('not before the throw has landed'),
          );
          await s.pump(kC468Frame);
          guard += 1;
          expect(
            guard,
            lessThan(80),
            reason: s.why('the throw lands within about a second'),
          );
        }
        await s.pump(kC468Frame);
        expect(
          s.count(FeedbackCue.dieLand),
          1,
          reason: s.why('landed on screen, so dieLand has played once'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  for (final (int me, int opp) in const <(int, int)>[(0, 2), (2, 0)]) {
    testWidgets(
      'D4.1: with reduced motion seat $opp\'s throw (seen from $me) plays '
      'dieLand at its start, once',
      (tester) async {
        final RollTrayDrive drive = await mountScreen(
          tester,
          mySeat: me,
          disableAnimations: true,
          turn: awaitRollTurn(opp),
          seats: pairSeats(mySeat: me),
        );
        final Scn s = Scn('D4.1 reduced me=$me opp=$opp', tester, drive);
        try {
          await s.push('rolled', rolledFrame(opp, 5, 1));
          expect(
            s.count(FeedbackCue.dieLand),
            1,
            reason: s.why(
              'with reduced motion the throw has already landed when it '
              'starts, so dieLand plays on the first frame',
            ),
          );
          await s.pump(_kThrowTotal);
          expect(s.drive.feedback.recorded, <FeedbackCue>[
            FeedbackCue.dieLand,
          ], reason: s.why('still exactly one after the overlay left'));
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D4.1: a queued second throw of the same seat gets its own dieLand when '
    'it lands, and not before',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2, queue: const <int>[]),
        seats: pairSeats(mySeat: 0, mine: const <int>[0, -1, -1, -1]),
      );
      final Scn s = Scn('D4.1 two throws', tester, drive);
      try {
        await s.push(
          'rolled',
          rolledFrame(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
        );
        await s.push(
          'rolled',
          rolledFrame(
            2,
            3,
            2,
            queue: const <int>[6, 3],
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[0]),
              faceLegal(3, const <int>[0]),
            ],
          ),
        );
        final int finished = await _watchThrows(s, 2, _kThrowTotal * 2);
        expect(finished, 2, reason: s.why('fixture: both throws landed'));
        expect(
          s.count(FeedbackCue.dieLand),
          2,
          reason: s.why('one dieLand per throw, two throws'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D4.1: a hurried throw (a moved while it is up) still plays exactly one '
    'dieLand',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2),
        seats: pairSeats(
          mySeat: 0,
          mine: const <int>[0, -1, -1, -1],
          opponent: const <int>[0, -1, -1, -1],
        ),
      );
      final Scn s = Scn('D4.1 hurried', tester, drive);
      try {
        await s.push('rolled', rolledFrame(2, 5, 1));
        expect(
          find.byKey(opponentThrowTumblingKey(2)),
          findsOneWidget,
          reason: s.why('fixture: the throw is up and tumbling'),
        );
        await s.push('moved', movedFrame(2, 0, 0, 5));
        await s.push('turn', turnFrame(0));
        final int finished = await _watchThrows(s, 2, _kThrowTotal);
        await s.pump(kC468Frame * 2);
        expect(
          finished,
          lessThanOrEqualTo(1),
          reason: s.why('at most one throw ever tumbled'),
        );
        expect(
          s.count(FeedbackCue.dieLand),
          1,
          reason: s.why('the hurried throw sounded exactly once'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D4.1: a replayed rolled frame (same sequence number) does not sound a '
    'second die',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2),
        seats: pairSeats(mySeat: 0),
      );
      final Scn s = Scn('D4.1 replay', tester, drive);
      try {
        final Map<String, Object?> data = rolledFrame(2, 5, 1);
        await s.push('rolled', data);
        await s.pump(_kThrowTotal);
        expect(s.count(FeedbackCue.dieLand), 1, reason: s.why('fixture'));
        s.steps.add('replay rolled with seq ${drive.lastSeq}');
        drive.transport.pushText(
          jsonEncode(<String, Object?>{
            'v': 1,
            't': 'rolled',
            'id': 'c468-replay-1',
            'd': <String, Object?>{...data, 'seq': drive.lastSeq},
          }),
        );
        await tester.pump();
        await tester.pump();
        await s.pump(_kThrowTotal);
        expect(
          s.count(FeedbackCue.dieLand),
          1,
          reason: s.why('a frame already applied must not sound again'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D4.1: four seats, seat 3 then seat 0 each roll once: one dieLand per '
    'roll, two in all',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        mySeat: 1,
        players: 4,
        turn: awaitRollTurn(3),
        seats: quadSeats(
          mySeat: 1,
          tokens: const <int, List<int>>{
            0: <int>[0, -1, -1, -1],
            2: <int>[0, -1, -1, -1],
            3: <int>[0, -1, -1, -1],
          },
        ),
      );
      final Scn s = Scn('D4.1 four seats', tester, drive);
      try {
        await s.push('rolled', rolledFrame(3, 4, 1));
        await s.pump(_kThrowTotal);
        expect(
          s.count(FeedbackCue.dieLand),
          1,
          reason: s.why('seat 3\'s roll sounded once'),
        );
        await s.push('moved', movedFrame(3, 0, 0, 4));
        await s.push('turn', turnFrame(0));
        await s.push('rolled', rolledFrame(0, 2, 1));
        await s.pump(_kThrowTotal);
        expect(
          s.count(FeedbackCue.dieLand),
          2,
          reason: s.why('seat 0\'s roll sounded once more'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets(
    'D4.1: the screen going away during the tumble never plays the cue '
    'afterwards',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2),
        seats: pairSeats(mySeat: 0),
      );
      final Scn s = Scn('D4.1 dispose mid tumble', tester, drive);
      await s.push('rolled', rolledFrame(2, 5, 1));
      expect(
        find.byKey(opponentThrowTumblingKey(2)),
        findsOneWidget,
        reason: s.why('fixture: tumbling'),
      );
      await s.pump(kC468Frame * 3);
      await releaseGame(tester, drive);
      await s.pump(_kThrowTotal);
      expect(
        s.count(FeedbackCue.dieLand),
        0,
        reason: s.why('a die that never landed on a live screen is silent'),
      );
    },
  );

  // -------------------------------------------------------------------
  // D4.2: my own roll.
  // -------------------------------------------------------------------
  for (final int me in const <int>[0, 2]) {
    testWidgets(
      'D4.2: my rolled with legal moves (seat $me) plays canMove and no '
      'dieLand',
      (tester) async {
        final RollTrayDrive drive = await mountScreen(
          tester,
          mySeat: me,
          turn: awaitRollTurn(me),
          seats: pairSeats(mySeat: me, mine: const <int>[0, -1, -1, -1]),
        );
        final Scn s = Scn('D4.2 canMove me=$me', tester, drive);
        try {
          await s.push('rolled', rolledFrame(me, 4, 1, legal: const <int>[0]));
          await s.pump(const Duration(milliseconds: 2500));
          expect(s.drive.feedback.recorded, <FeedbackCue>[
            FeedbackCue.canMove,
          ], reason: s.why('canMove alone: my die landing is that clip'));
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    testWidgets('D4.2: my no-move roll (seat $me) plays noMove and no dieLand, '
        'also after the turn passes', (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        mySeat: me,
        turn: awaitRollTurn(me),
        seats: pairSeats(mySeat: me),
      );
      final Scn s = Scn('D4.2 noMove me=$me', tester, drive);
      try {
        await s.push('rolled', rolledFrame(me, 3, 1, legal: const <int>[]));
        expect(
          s.count(FeedbackCue.noMove),
          1,
          reason: s.why('noMove plays on my dead roll'),
        );
        await s.push('turn', turnFrame(me == 0 ? 2 : 0));
        await s.pump(const Duration(milliseconds: 2500));
        expect(
          s.count(FeedbackCue.dieLand),
          0,
          reason: s.why('noMove is my die landing, so no dieLand'),
        );
        expect(
          s.count(FeedbackCue.canMove),
          0,
          reason: s.why('a dead roll never plays canMove'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    testWidgets(
      'D4.2: my 6 that owes another roll with nothing to move yet (seat '
      '$me) plays dieLand and neither canMove nor noMove',
      (tester) async {
        final RollTrayDrive drive = await mountScreen(
          tester,
          mySeat: me,
          turn: awaitRollTurn(me),
          seats: pairSeats(mySeat: me),
        );
        final Scn s = Scn('D4.2 owed six me=$me', tester, drive);
        try {
          await s.push(
            'rolled',
            rolledFrame(me, 6, 1, legal: const <int>[], queue: const <int>[6]),
          );
          expect(
            s.count(FeedbackCue.dieLand),
            1,
            reason: s.why('the landing of a die that owes a roll is heard'),
          );
          expect(
            s.count(FeedbackCue.noMove),
            0,
            reason: s.why('the roll-queue filter removes noMove'),
          );
          expect(
            s.count(FeedbackCue.canMove),
            0,
            reason: s.why('nothing to move, so no canMove'),
          );
          await s.push('turn', turnFrame(me, queue: const <int>[6]));
          await s.pump(const Duration(milliseconds: 2500));
          expect(
            s.count(FeedbackCue.dieLand),
            1,
            reason: s.why('once per roll, not again on the same-seat turn'),
          );
          expect(
            s.count(FeedbackCue.noMove) + s.count(FeedbackCue.canMove),
            0,
            reason: s.why('neither own-die clip for this roll'),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets(
    'D4.2: my 6 with a legal move on a queue plays canMove and no dieLand',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(0),
        seats: pairSeats(mySeat: 0, mine: const <int>[0, -1, -1, -1]),
      );
      final Scn s = Scn('D4.2 six with a move', tester, drive);
      try {
        await s.push(
          'rolled',
          rolledFrame(
            0,
            6,
            1,
            legal: const <int>[0],
            queue: const <int>[6],
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[0]),
            ],
          ),
        );
        await s.pump(const Duration(milliseconds: 1000));
        expect(s.drive.feedback.recorded, <FeedbackCue>[
          FeedbackCue.canMove,
        ], reason: s.why('canMove alone'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  testWidgets('D4.2: two owed sixes in a row sound one die '
      'per roll, none of them noMove', (tester) async {
    final RollTrayDrive drive = await mountScreen(
      tester,
      turn: awaitRollTurn(0),
      seats: pairSeats(mySeat: 0),
    );
    final Scn s = Scn('D4.2 two owed sixes', tester, drive);
    try {
      await s.push(
        'rolled',
        rolledFrame(0, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await s.push('turn', turnFrame(0, queue: const <int>[6]));
      await s.push(
        'rolled',
        rolledFrame(0, 6, 2, legal: const <int>[], queue: const <int>[6, 6]),
      );
      expect(
        s.count(FeedbackCue.dieLand),
        2,
        reason: s.why('one dieLand per owed-six roll'),
      );
      expect(
        s.count(FeedbackCue.noMove),
        0,
        reason: s.why('owed sixes are not dead rolls'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });
}
