// docs/RULES.md rule 38 and docs/ENGINE_API.md sections 3, 4 and 5: the
// engine draws no randomness of its own. A RollIntention now carries the
// face it was drawn with; apply() validates that face is an integer 1..6
// and applies the rules to it, and that is the whole of the engine's
// involvement with dice. This file used to prove the engine's own draw was
// uniform and reproducible from a seed; that behaviour is gone, and what
// replaces it is the guard the change needs: badFace rejects anything that
// is not 1..6, the ladder puts that check at step 5, and the engine must
// visibly never draw on its own, not even quietly, alongside what it used
// to draw.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('rule 38 / docs/ENGINE_API.md section 4 step 5: badFace', () {
    for (final face in const [0, 7, -1, 99, -6, 1000000]) {
      test(
        'face=$face is rejected with badFace, and the state passed in is '
        'left untouched',
        () {
          final state = buildAwaitRoll(
            seats: twoPlayerSeats,
            currentSeat: 0,
            rngState: 1,
          );
          final beforeJson = state.toJson();
          final beforeHash = stateHash(state);

          final result = apply(state, RollIntention(0, face));

          expect(result, isA<Rejected>(), reason: 'face=$face');
          expect(
            (result as Rejected).error,
            EngineError.badFace,
            reason: 'face=$face',
          );

          // docs/ENGINE_API.md section 4: "Rejected ... No state field. A
          // rejected intention changes nothing, by construction." Since a
          // Rejected result carries no state at all, the only state that
          // exists after this call is the very object the caller already
          // held: apply() is never handed a channel to substitute a
          // different-but-equal object in its place, only the option to
          // leave `state` alone or to have mutated it. These checks rule
          // out the mutation: same serialised form, same hash, and (per
          // GameState's == contract in section 2) still equal to an
          // independently rebuilt copy from the JSON snapshot taken before
          // the call.
          expect(state.toJson(), equals(beforeJson), reason: 'face=$face');
          expect(stateHash(state), beforeHash, reason: 'face=$face');
          expect(
            state,
            equals(GameState.fromJson(beforeJson)),
            reason: 'face=$face',
          );
        },
      );
    }
  });

  group(
      'docs/ENGINE_API.md section 4: badFace sits at step 5, after the '
      'terminal, seat and phase checks', () {
    test('face=99 from a seat that is not currentSeat gives notYourTurn', () {
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        rngState: 1,
      );
      final result = apply(state, const RollIntention(2, 99));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.notYourTurn);
    });

    test('face=99 from a seat not in config.seats gives seatNotInPlay', () {
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        rngState: 1,
      );
      final result = apply(state, const RollIntention(1, 99));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.seatNotInPlay);
    });

    test('face=99 against a finished state gives gameFinished', () {
      final finished = buildState(
        seats: twoPlayerSeats,
        phase: 'finished',
        winner: 0,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 57, 57],
        },
      );
      final result = apply(finished, const RollIntention(0, 99));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.gameFinished);
    });

    test('face=99 in phase awaitMove gives wrongPhase', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[0, -1, -1, -1],
        },
      );
      final result = apply(state, const RollIntention(0, 99));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.wrongPhase);
    });

    test(
      'face=99 from the right seat in the right phase gives badFace, not '
      'a phase or turn error',
      () {
        final state = buildAwaitRoll(
          seats: twoPlayerSeats,
          currentSeat: 0,
          rngState: 1,
        );
        final result = apply(state, const RollIntention(0, 99));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.badFace);
      },
    );
  });

  test(
    'every face 1..6 is accepted in awaitRoll from the seat whose turn it '
    'is, opening awaitMove with that value',
    () {
      for (final face in const [1, 2, 3, 4, 5, 6]) {
        // Token 0 on the track at progress 10 has a legal move for every
        // face 1..6 (10 + face never overshoots 57 and never needs a yard
        // exit), so acceptance here is never confused with rule 7's
        // turn-pass path, which is also an Applied result but a different
        // one.
        final state = buildAwaitRoll(
          seats: twoPlayerSeats,
          currentSeat: 0,
          rngState: 1,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        final result = apply(state, RollIntention(0, face));
        expect(result, isA<Applied>(), reason: 'face=$face, got $result');
        final applied = result as Applied;
        expect(applied.state.phase, GamePhase.awaitMove, reason: 'face=$face');
        expect(applied.state.roll, face, reason: 'face=$face');
      }
    },
  );

  test(
    'the engine never draws: the Rolled event always carries exactly the '
    'face given in the intention, for every face 1..6, never a value '
    'derived from rngState',
    () {
      // rngState is held fixed across every one of these six calls. An
      // implementation that quietly still draws from rngState instead of
      // reading intention.face would draw the very same single value on
      // every call here, since rngState never changes between them, and
      // this loop would catch that: six different requested faces would
      // not produce six different reported values.
      const fixedRngState = 1;
      for (final face in const [1, 2, 3, 4, 5, 6]) {
        final state = buildAwaitRoll(
          seats: twoPlayerSeats,
          currentSeat: 0,
          rngState: fixedRngState,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        final result = apply(state, RollIntention(0, face));
        expect(result, isA<Applied>(), reason: 'face=$face');
        final applied = result as Applied;
        final rolled = applied.events.whereType<Rolled>().single;
        expect(
          rolled.value,
          face,
          reason: 'rngState was held fixed at $fixedRngState for every face '
              'in this loop; Rolled.value must equal the face that was '
              'sent, face=$face, regardless of what that fixed rngState '
              'would otherwise have drawn',
        );
        expect(applied.state.roll, face, reason: 'face=$face');
      }
    },
  );

  test(
    'rngState does not move across a roll, in every path the roll step '
    'can take',
    () {
      const startingRngState = 424242;

      // Path 1: the roll opens awaitMove.
      for (final face in const [1, 2, 3, 4, 5, 6]) {
        final state = buildAwaitRoll(
          seats: twoPlayerSeats,
          currentSeat: 0,
          rngState: startingRngState,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        final result = apply(state, RollIntention(0, face));
        expect(result, isA<Applied>(), reason: 'face=$face');
        expect(
          (result as Applied).state.rngState,
          startingRngState,
          reason: 'face=$face, awaitMove path: rule 38 says the engine '
              'draws no randomness at all, so nothing may move rngState on '
              'a roll',
        );
      }

      // Path 2: rule 7, an empty legal set passes the turn immediately.
      final turnPassState = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        rngState: startingRngState,
        tokens: const {
          0: <int>[-1, 57, 57, 57],
        },
      );
      final turnPassResult = apply(turnPassState, const RollIntention(0, 5));
      expect(turnPassResult, isA<Applied>());
      expect(
        (turnPassResult as Applied).state.rngState,
        startingRngState,
        reason: 'rule 7 turn-pass path must not move rngState either',
      );

      // Path 3: rule 10, the third consecutive 6 forfeits the turn.
      final threeSixesState = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        sixes: 2,
        rngState: startingRngState,
        tokens: const {
          0: <int>[20, -1, -1, -1],
        },
      );
      final threeSixesResult = apply(threeSixesState, const RollIntention(0, 6));
      expect(threeSixesResult, isA<Applied>());
      expect(
        (threeSixesResult as Applied).state.rngState,
        startingRngState,
        reason: 'rule 10 three-sixes-forfeit path must not move rngState '
            'either',
      );
    },
  );
}
