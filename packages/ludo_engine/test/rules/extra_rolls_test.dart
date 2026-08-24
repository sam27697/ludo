// docs/RULES.md section 3.2, rules 9-12: extra rolls.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/splitmix64.dart';

void main() {
  test(
    'rule 9: rolling a 6 grants the player another roll after the '
    'resulting move is applied',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        currentSeat: 0,
        sixes: 1,
        tokens: const {
          0: <int>[0, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
      expect(applied.state.sixes, 1);
      expect(applied.state.roll, isNull);
    },
  );

  test(
    'rule 10: three consecutive 6s forfeit the turn and the third 6 is not '
    'played',
    () {
      // sixes = 2 models the first two 6s already having happened this
      // turn. Token 0 sits well inside the track so a third 6 would
      // otherwise be a perfectly legal advance; rule 10 says it must not be
      // offered at all.
      final rngState = findRngStateForNextRoll(6);
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        sixes: 2,
        rngState: rngState,
        tokens: const {
          0: <int>[20, -1, -1, -1],
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
              .having((e) => e.value, 'value', 6),
          isA<TurnEnded>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.reason, 'reason', TurnEndReason.threeSixes),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(
        applied.events.whereType<Moved>(),
        isEmpty,
        reason: 'the third six is not played: no move happens',
      );
      expect(
        applied.state.tokens[0][0],
        20,
        reason: 'the token that would have been legal to move must not move',
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(applied.state.sixes, 0);
      expect(applied.state.roll, isNull);
    },
  );

  group('rule 11: a capture grants another roll (captureBonus on)', () {
    test('a capturing move grants an extra roll when captureBonus is on', () {
      // seat 0 token at progress 10 (absolute 10) moves to progress 12
      // (absolute 12) on a roll of 2. seat 2 token at progress 38 sits at
      // absolute (26 + 38) mod 52 = 12, the same square, and 12 is not a
      // safe square.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 2,
        currentSeat: 0,
        sixes: 0,
        captureBonus: true,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<Captured>(),
          isA<ExtraRoll>().having((e) => e.seat, 'seat', 0),
        ]),
      );
      expect(applied.state.tokens[2][0], -1);
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
    });

    test('the same capture grants no extra roll when captureBonus is off', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 2,
        currentSeat: 0,
        sixes: 0,
        captureBonus: false,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(applied.state.tokens[2][0], -1, reason: 'rule 27 still applies');
      expect(applied.events.whereType<ExtraRoll>(), isEmpty);
      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<Captured>(),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(applied.state.sixes, 0);
    });
  });

  test(
    'rule 12: extra rolls are a single boolean, not a stack: a move that is '
    'both a 6 and a capture grants exactly one extra roll',
    () {
      // seat 0 token at progress 10 moves to progress 16 on a roll of 6.
      // seat 2 token at progress 42 sits at absolute (26 + 42) mod 52 = 16,
      // the same square, and 16 is not a safe square.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        currentSeat: 0,
        sixes: 1,
        captureBonus: true,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[42, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(applied.state.tokens[2][0], -1);
      expect(
        applied.events.whereType<ExtraRoll>(),
        hasLength(1),
        reason: 'a six and a capture together must not grant two extra rolls',
      );
      expect(
        applied.state.sixes,
        1,
        reason: 'sixes was already incremented by the roll step and must not '
            'be incremented again by the capture bonus',
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
    },
  );

  test(
    'rule 12: the sixes counter resets to 0 on a non-6, non-capturing move '
    'that ends the turn (a change of hands)',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        sixes: 0,
        tokens: const {
          0: <int>[10, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(applied.events.whereType<ExtraRoll>(), isEmpty);
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2, reason: 'turn changes hands');
      expect(applied.state.sixes, 0);
    },
  );
}
