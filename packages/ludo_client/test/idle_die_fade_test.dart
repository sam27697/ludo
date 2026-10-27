// Screen proof for C-468 D7 (order 469): the big die under the board draws
// at 45 percent opacity while another seat holds the turn and my no-move
// hold is not up; full opacity on my turn and while my hold is up. The
// opacity is read from the nearest Opacity between the die's art and the
// game-die root key. Written from the contract's text alone.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it.

import 'package:flutter_test/flutter_test.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

/// The opacity the die's art paints at: the nearest Opacity under
/// game-die, or 1.0 when the art has none.
double _opacity(Scn s, Finder art, {required bool mustExist}) {
  expect(
    art,
    findsOneWidget,
    reason: s.why('the big die\'s art ($art) is on screen'),
  );
  final double? found = nearestOpacityUnderBigDie(s.tester, art);
  if (mustExist) {
    expect(
      found,
      isNotNull,
      reason: s.why('an Opacity ancestor of the art under game-die'),
    );
  }
  return found ?? 1.0;
}

void main() {
  for (final int me in const <int>[0, 2]) {
    final int opp = me == 0 ? 2 : 0;

    testWidgets(
      'D7: on seat $opp\'s turn my idle big die (seat $me) is at 0.45, '
      'before and after seat $opp\'s throw and while it holds the turn',
      (tester) async {
        final RollTrayDrive drive = await mountScreen(
          tester,
          mySeat: me,
          turn: awaitRollTurn(opp),
          seats: pairSeats(
            mySeat: me,
            mine: const <int>[0, -1, -1, -1],
            opponent: const <int>[0, -1, -1, -1],
          ),
        );
        final Scn s = Scn('D7 other turn me=$me', tester, drive);
        try {
          await s.pump(const Duration(milliseconds: 800));
          expect(
            _opacity(s, find.byKey(idleArtKey), mustExist: true),
            closeTo(0.45, 0.01),
            reason: s.why('idle big die on seat $opp\'s turn'),
          );
          await s.push('rolled', rolledFrame(opp, 5, 1));
          await s.pump(const Duration(milliseconds: 2500));
          expect(
            _opacity(s, find.byKey(idleArtKey), mustExist: true),
            closeTo(0.45, 0.01),
            reason: s.why('after seat $opp\'s throw, still its turn'),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  }

  testWidgets('D7: on my turn the big die is at full opacity, idle and with '
      'my face', (tester) async {
    final RollTrayDrive drive = await mountScreen(
      tester,
      turn: awaitRollTurn(0),
      seats: pairSeats(mySeat: 0, mine: const <int>[0, -1, -1, -1]),
    );
    final Scn s = Scn('D7 my turn', tester, drive);
    try {
      await s.pump(const Duration(milliseconds: 800));
      expect(
        _opacity(s, find.byKey(idleArtKey), mustExist: false),
        closeTo(1.0, 0.01),
        reason: s.why('idle big die on my turn'),
      );
      await s.push('rolled', rolledFrame(0, 4, 1));
      await s.pump(const Duration(milliseconds: 800));
      expect(
        _opacity(s, find.byKey(bigFaceKey(4)), mustExist: false),
        closeTo(1.0, 0.01),
        reason: s.why('my face 4 on my turn'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets('D7: the die dims when the turn passes to the other seat and '
      'comes back to full on my next turn', (tester) async {
    final RollTrayDrive drive = await mountScreen(
      tester,
      turn: awaitRollTurn(0),
      seats: pairSeats(mySeat: 0, mine: const <int>[0, -1, -1, -1]),
    );
    final Scn s = Scn('D7 passes', tester, drive);
    try {
      await s.pump(const Duration(milliseconds: 800));
      await s.push('turn', turnFrame(2));
      await s.pump(const Duration(milliseconds: 800));
      expect(
        _opacity(s, find.byKey(idleArtKey), mustExist: true),
        closeTo(0.45, 0.01),
        reason: s.why('seat 2 holds the turn'),
      );
      await s.push('turn', turnFrame(0));
      await s.pump(const Duration(milliseconds: 800));
      expect(
        _opacity(s, find.byKey(idleArtKey), mustExist: false),
        closeTo(1.0, 0.01),
        reason: s.why('my turn again'),
      );
    } finally {
      await releaseGame(tester, drive);
    }
  });

  testWidgets(
    'D7: while my no-move hold is up after my dead roll and seat 2\'s turn '
    'has begun the die is at full opacity; once the hold ends it is 0.45',
    (tester) async {
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(0),
        seats: pairSeats(mySeat: 0),
      );
      final Scn s = Scn('D7 no-move hold', tester, drive);
      try {
        await s.push('rolled', rolledFrame(0, 3, 1, legal: const <int>[]));
        await s.push('turn', turnFrame(2));
        expect(
          drive.controller.room!.turn!.seat,
          2,
          reason: s.why('fixture: seat 2\'s turn has begun'),
        );
        await s.pump(const Duration(milliseconds: 800));
        expect(
          find.byKey(noMoveMarkKey),
          findsOneWidget,
          reason: s.why('fixture: my no-move hold is up'),
        );
        expect(
          _opacity(s, find.byKey(bigFaceKey(3)), mustExist: false),
          closeTo(1.0, 0.01),
          reason: s.why('hold up: my dead face at full opacity'),
        );
        await s.pump(const Duration(milliseconds: 1000));
        expect(
          find.byKey(noMoveMarkKey),
          findsNothing,
          reason: s.why('fixture: the hold has ended'),
        );
        expect(
          _opacity(s, find.byKey(idleArtKey), mustExist: true),
          closeTo(0.45, 0.01),
          reason: s.why('hold over, seat 2 still holds the turn'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );
}
