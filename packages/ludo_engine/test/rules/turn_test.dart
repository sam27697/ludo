// docs/RULES.md section 3.1 (rolling, rules 5-8) and rule 13 (rule 7 applies
// identically to an extra roll).

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/splitmix64.dart';

void main() {
  test('rule 5: a roll is a uniform integer 1 to 6 inclusive', () {
    for (final want in const [1, 2, 3, 4, 5, 6]) {
      final rngState = findRngStateForNextRoll(want);
      final state = buildAwaitRoll(seats: twoPlayerSeats, rngState: rngState);
      final result = apply(state, const RollIntention(0));
      expect(result, isA<Applied>());
      final rolled = (result as Applied).events.whereType<Rolled>().single;
      expect(rolled.value, want, reason: 'rngState=$rngState');
      expect(rolled.value, inInclusiveRange(1, 6));
    }
  });

  test(
    'rule 6: after the roll, the engine computes the legal set for that '
    'seat and that value',
    () {
      // token 0 at 10 can advance to 12: legal.
      // token 1 in the yard needs a 6, not a 2: illegal.
      // token 2 at 55 needs exactly 2 to reach home at 57: legal.
      // token 3 already home at 57 is never movable again: illegal.
      final rngState = findRngStateForNextRoll(2);
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        rngState: rngState,
        tokens: const {
          0: <int>[10, -1, 55, 57],
        },
      );
      final result = apply(state, const RollIntention(0));
      expect(result, isA<Applied>(), reason: 'rngState=$rngState');
      final applied = result as Applied;
      expect(applied.state.roll, 2);
      expect(applied.state.phase, GamePhase.awaitMove);
      final rolled = applied.events.whereType<Rolled>().single;
      expect(rolled.value, 2);
      expect(rolled.legal, const <int>[0, 2]);
      expect(legalTokens(applied.state), const <int>[0, 2]);
    },
  );

  test(
    'rule 7: an empty legal set passes the turn immediately, with no error '
    'and no move',
    () {
      final rngState = findRngStateForNextRoll(4);
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        rngState: rngState,
      );
      final result = apply(state, const RollIntention(0));
      expect(result, isA<Applied>(), reason: 'rngState=$rngState');
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Rolled>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.value, 'value', 4)
              .having((e) => e.legal, 'legal', isEmpty),
          isA<TurnEnded>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.reason, 'reason', TurnEndReason.noLegalMove),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(applied.state.roll, isNull);
      expect(applied.state.sixes, 0);
    },
  );

  test(
    'rule 8: selecting a token with no legal move for this roll is '
    'rejected and the turn does not change hands',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[-1, 0, 57, 57],
        },
      );
      // token 0 is in the yard; roll is 3, not 6, so it has no legal move.
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);

      // The rejected call had no effect: the same fixture still accepts the
      // legal token for this roll, currentSeat and roll unchanged.
      final second = apply(state, const MoveIntention(0, 1));
      expect(second, isA<Applied>());
      expect((second as Applied).state.tokens[0][1], 3);
    },
  );

  test(
    'rule 13: rule 7 applies to an extra roll exactly as it applies to a '
    'first roll',
    () {
      // sixes = 1 models a turn already one six in, mid extra-roll. Token 0
      // sits at 56, so only a roll of exactly 1 is legal for it; tokens 1-3
      // are in the yard and need a 6. A roll of 3 leaves nothing legal.
      final rngState = findRngStateForNextRoll(3);
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        sixes: 1,
        rngState: rngState,
        tokens: const {
          0: <int>[56, -1, -1, -1],
        },
      );
      final result = apply(state, const RollIntention(0));
      expect(result, isA<Applied>(), reason: 'rngState=$rngState');
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Rolled>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.value, 'value', 3)
              .having((e) => e.legal, 'legal', isEmpty),
          isA<TurnEnded>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.reason, 'reason', TurnEndReason.noLegalMove),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(
        applied.state.sixes,
        0,
        reason: 'the counter resets when the turn changes hands, rule 9-12',
      );
      expect(applied.state.tokens[0][0], 56, reason: 'no move was played');
    },
  );
}
