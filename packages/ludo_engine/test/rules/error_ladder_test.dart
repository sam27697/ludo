// docs/ENGINE_API.md section 4, "The order of checks in apply": one test
// per EngineError, plus tests proving the fixed order itself, since the
// error a client sees must not depend on an implementation detail.
//
// 1. isTerminal(state)                              -> gameFinished
// 2. intention.seat not in config.seats              -> seatNotInPlay
// 3. intention.seat != state.currentSeat             -> notYourTurn
// 4. intention type does not match state.phase       -> wrongPhase
// 5. RollIntention.face not an integer in 1..6       -> badFace
// 6. MoveIntention.token outside 0..3                -> noSuchToken
// 7. MoveIntention.token not in legalTokens(state)    -> illegalMove
//
// The badFace step is exercised in depth, including its exact position in
// this order relative to every other check, by test/rules/dice_test.dart;
// the entry here exists so this file's own "one test per EngineError"
// promise stays true of all seven values, not six.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('one test per EngineError', () {
    test('gameFinished: any intention against a terminal state', () {
      final finished = buildState(
        seats: twoPlayerSeats,
        phase: 'finished',
        winner: 0,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 57, 57],
        },
      );
      final result = apply(finished, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.gameFinished);
    });

    test('seatNotInPlay: a seat index not in config.seats', () {
      final state = buildAwaitRoll(seats: twoPlayerSeats, rngState: 1);
      final result = apply(state, const RollIntention(1, 4));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.seatNotInPlay);
    });

    test('notYourTurn: a seat in play that is not the current seat', () {
      final state =
          buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
      final result = apply(state, const RollIntention(2, 4));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.notYourTurn);
    });

    test('wrongPhase: RollIntention while phase is awaitMove', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[0, -1, -1, -1],
        },
      );
      final result = apply(state, const RollIntention(0, 4));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.wrongPhase);
    });

    test('wrongPhase: MoveIntention while phase is awaitRoll', () {
      final state =
          buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.wrongPhase);
    });

    test(
      'badFace: RollIntention.face outside 1..6 from the right seat in '
      'the right phase',
      () {
        final state = buildAwaitRoll(
          seats: twoPlayerSeats,
          currentSeat: 0,
          rngState: 1,
        );
        final result = apply(state, const RollIntention(0, 0));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.badFace);
      },
    );

    test('noSuchToken: MoveIntention.token outside 0..3', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[0, -1, -1, -1],
        },
      );
      for (final token in const [-1, 4, 99]) {
        final result = apply(state, MoveIntention(0, token));
        expect(result, isA<Rejected>(), reason: 'token=$token');
        expect((result as Rejected).error, EngineError.noSuchToken,
            reason: 'token=$token');
      }
    });

    test('illegalMove: MoveIntention.token in 0..3 but not in legalTokens', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[-1, 0, 57, 57],
        },
      );
      expect(legalTokens(state), const <int>[1]);
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    });
  });

  group(
      'the checks fire in the fixed order, not by seat or phase '
      'convenience', () {
    test(
      'an intention that is simultaneously out of turn and for a finished '
      'game returns gameFinished, not notYourTurn (checks 1 before 3)',
      () {
        final finished = buildState(
          seats: twoPlayerSeats,
          phase: 'finished',
          winner: 0,
          currentSeat: 0,
          tokens: const {
            0: <int>[57, 57, 57, 57],
          },
        );
        // seat 2 is in play but is not currentSeat, and the game is over.
        final result = apply(finished, const RollIntention(2, 4));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.gameFinished);
      },
    );

    test(
      'a seat not in play that is also not the current seat returns '
      'seatNotInPlay, not notYourTurn (checks 2 before 3)',
      () {
        final state =
            buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
        // seat 1 is neither in twoPlayerSeats nor currentSeat.
        final result = apply(state, const RollIntention(1, 4));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.seatNotInPlay);
      },
    );

    test(
      'an intention that is simultaneously out of turn and the wrong '
      'phase returns notYourTurn, not wrongPhase (checks 3 before 4)',
      () {
        final state =
            buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
        // seat 2 is in play but not currentSeat, and a MoveIntention is
        // the wrong intention type for awaitRoll regardless of seat.
        final result = apply(state, const MoveIntention(2, 0));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.notYourTurn);
      },
    );

    test(
      'a MoveIntention with an out-of-range token sent during awaitRoll '
      'returns wrongPhase, not noSuchToken (checks 4 before 6)',
      () {
        final state =
            buildAwaitRoll(seats: twoPlayerSeats, currentSeat: 0, rngState: 1);
        final result = apply(state, const MoveIntention(0, 99));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.wrongPhase);
      },
    );
  });
}
