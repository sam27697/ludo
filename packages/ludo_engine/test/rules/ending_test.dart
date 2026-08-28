// docs/RULES.md section 5, rules 33-35: ending.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test('rule 33: the first seat to bring all 4 tokens to 57 wins', () {
    final state = buildAwaitMove(
      seats: twoPlayerSeats,
      roll: 2,
      currentSeat: 0,
      tokens: const {
        0: <int>[57, 57, 57, 55],
        2: <int>[10, -1, -1, -1],
      },
    );
    final result = apply(state, const MoveIntention(0, 3));
    expect(result, isA<Applied>());
    final applied = result as Applied;
    expect(applied.state.tokens[0], const <int>[57, 57, 57, 57]);
    expect(applied.state.winner, 0);
    expect(applied.state.phase, GamePhase.finished);
    expect(applied.events.whereType<GameWon>().single.seat, 0);
  });

  test(
    'rule 34: the game ends the moment a seat wins; a winning move grants '
    'no extra roll even when the roll was a 6, and nothing is emitted '
    'after GameWon',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 57, 51],
          2: <int>[10, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 3));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(
        applied.events,
        equals(<Object?>[
          isA<Moved>(),
          isA<TokenHome>(),
          isA<GameWon>().having((e) => e.seat, 'seat', 0),
        ]),
      );
      expect(applied.events.whereType<ExtraRoll>(), isEmpty);
      expect(applied.events.whereType<TurnBegan>(), isEmpty);
      expect(applied.state.phase, GamePhase.finished);
      expect(applied.state.winner, 0);
    },
  );

  group(
    'rule 35: a game state where a winner exists is terminal; no further '
    'roll, move or timer is accepted against it',
    () {
      test('a roll intention is rejected with gameFinished', () {
        final finished = buildState(
          seats: twoPlayerSeats,
          phase: 'finished',
          winner: 2,
          currentSeat: 0,
          tokens: const {
            2: <int>[57, 57, 57, 57],
          },
        );
        expect(isTerminal(finished), isTrue);
        final result = apply(finished, const RollIntention(0, 4));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.gameFinished);
      });

      test(
        'a move intention (including one shaped like the timer would '
        'submit) is rejected with gameFinished',
        () {
          final finished = buildState(
            seats: twoPlayerSeats,
            phase: 'finished',
            winner: 2,
            currentSeat: 0,
            tokens: const {
              0: <int>[10, -1, -1, -1],
              2: <int>[57, 57, 57, 57],
            },
          );
          final result = apply(finished, const MoveIntention(0, 0));
          expect(result, isA<Rejected>());
          expect((result as Rejected).error, EngineError.gameFinished);
        },
      );
    },
  );
}
