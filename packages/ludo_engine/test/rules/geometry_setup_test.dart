// docs/RULES.md section 1 (the board, entry offsets, safe squares) and
// section 2 (setup, rules 1-4).
//
// The entry offset table in section 1.1 is not itself a numbered rule, so it
// is proven indirectly here through capture: two seats whose progress values
// land on the same absolute square, per their respective entry offsets, must
// interact on that square. If the offset table were wired wrong, this
// capture would either not happen or happen on the wrong pair of squares.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/splitmix64.dart';

void main() {
  group('rule 1: setup', () {
    test('a game may have 2, 3 or 4 players, each with exactly 4 tokens', () {
      for (final seats in const [
        <int>[0, 2],
        <int>[0, 1, 2],
        <int>[0, 1, 2, 3],
      ]) {
        final state = newGame(
          GameConfig(seats: seats, rules: const RulesConfig(), seed: 1),
        );
        expect(state.tokens, hasLength(4));
        for (final row in state.tokens) {
          expect(row, hasLength(4));
        }
      }
    });

    test('newGame rejects a seat list shorter than 2', () {
      expect(
        () => newGame(
          GameConfig(
              seats: const <int>[0], rules: const RulesConfig(), seed: 1),
        ),
        throwsArgumentError,
      );
    });

    test('newGame rejects a seat list longer than 4', () {
      expect(
        () => newGame(
          GameConfig(
            seats: const <int>[0, 1, 2, 3, 0],
            rules: const RulesConfig(),
            seed: 1,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('rule 2: seats assigned by join order', () {
    test('newGame accepts the fixed seat lists for 2, 3 and 4 players', () {
      for (final seats in const [
        <int>[0, 2],
        <int>[0, 1, 2],
        <int>[0, 1, 2, 3],
      ]) {
        final state = newGame(
          GameConfig(seats: seats, rules: const RulesConfig(), seed: 1),
        );
        for (final seat in seats) {
          expect(state.tokens[seat], equals(const <int>[-1, -1, -1, -1]));
        }
      }
    });

    test('newGame rejects seats that are not ascending', () {
      expect(
        () => newGame(
          GameConfig(
              seats: const <int>[2, 0], rules: const RulesConfig(), seed: 1),
        ),
        throwsArgumentError,
      );
    });

    test('newGame rejects duplicate seats', () {
      expect(
        () => newGame(
          GameConfig(
              seats: const <int>[0, 0], rules: const RulesConfig(), seed: 1),
        ),
        throwsArgumentError,
      );
    });

    test('newGame rejects a seat index outside 0..3', () {
      expect(
        () => newGame(
          GameConfig(
              seats: const <int>[0, 4], rules: const RulesConfig(), seed: 1),
        ),
        throwsArgumentError,
      );
    });

    test(
      'seats not in config.seats keep [-1,-1,-1,-1] forever and are never '
      'legal to move',
      () {
        final state = newGame(
          GameConfig(
              seats: twoPlayerSeats, rules: const RulesConfig(), seed: 1),
        );
        expect(state.tokens[1], equals(const <int>[-1, -1, -1, -1]));
        expect(state.tokens[3], equals(const <int>[-1, -1, -1, -1]));

        // Even placed in awaitMove artificially, an unoccupied seat's tokens
        // must never appear in legalTokens for that seat, because the state
        // still enforces seatNotInPlay before anything else looks at tokens.
        final awaitMove = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 6,
          currentSeat: 1,
          tokens: const {
            1: <int>[-1, -1, -1, -1]
          },
        );
        final result = apply(awaitMove, const MoveIntention(1, 0));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.seatNotInPlay);
      },
    );
  });

  test('rule 3: every token starts at progress -1', () {
    final state = newGame(
      GameConfig(seats: fourPlayerSeats, rules: const RulesConfig(), seed: 7),
    );
    for (final seat in fourPlayerSeats) {
      for (final progress in state.tokens[seat]) {
        expect(progress, -1);
      }
    }
  });

  group('rule 4: turn order', () {
    test(
      'newGame starts with currentSeat equal to the lowest occupied seat',
      () {
        expect(
          newGame(
            GameConfig(
                seats: twoPlayerSeats, rules: const RulesConfig(), seed: 1),
          ).currentSeat,
          0,
        );
        expect(
          newGame(
            GameConfig(
                seats: const <int>[1, 2, 3],
                rules: const RulesConfig(),
                seed: 1),
          ).currentSeat,
          1,
        );
      },
    );

    test(
      'turn order is ascending seat index, wrapping to the lowest occupied '
      'seat rather than to seat 0',
      () {
        const seats = <int>[1, 2, 3];
        // Every token in the yard and a non-six roll gives an empty legal
        // set, so rule 7 passes the turn with no move played, and we only
        // need one controlled draw to observe where the turn goes next.
        final rngState = findRngStateForNextRoll(3);
        final state = buildAwaitRoll(
          seats: seats,
          currentSeat: 3,
          rngState: rngState,
        );
        final result = apply(state, const RollIntention(3));
        expect(
          result,
          isA<Applied>(),
          reason: 'seed=$rngState should draw a 3, expect $result',
        );
        final applied = result as Applied;
        expect(
          applied.state.currentSeat,
          1,
          reason: 'seat 3 is the highest occupied seat in $seats; the next '
              'turn must wrap to the lowest occupied seat, 1, not to seat 0 '
              '(unoccupied) or seat 4 (out of range). seed=$rngState',
        );
      },
    );
  });

  group('entry offset table (section 1.1)', () {
    test(
      'seat 0 progress 10 and seat 2 progress 36 share absolute square 10, '
      'per entry offsets 0 and 26, so seat 0 landing there captures seat 2',
      () {
        // absolute(seat0, 10) = (0 + 10) mod 52 = 10
        // absolute(seat2, 36) = (26 + 36) mod 52 = 10
        expect(safeSquares.contains(10), isFalse);
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 1,
          currentSeat: 0,
          tokens: const {
            0: <int>[9, -1, -1, -1],
            2: <int>[36, -1, -1, -1],
          },
        );
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.tokens[0][0], 10);
        expect(
          applied.state.tokens[2][0],
          -1,
          reason: 'seat 2 token at progress 36 sits on absolute square 10 via '
              'entry offset 26; seat 0 moving to progress 10 (entry offset '
              '0) reaches the same square and must capture it',
        );
        expect(
          applied.events.whereType<Captured>().single,
          isA<Captured>()
              .having((c) => c.seat, 'victim seat', 2)
              .having((c) => c.token, 'victim token', 0)
              .having((c) => c.by, 'capturer seat', 0)
              .having((c) => c.byToken, 'capturer token', 0),
        );
      },
    );

    test(
      'seat 1 progress 7 and seat 3 progress 33 share absolute square 20, '
      'per entry offsets 13 and 39, so seat 1 landing there captures seat 3',
      () {
        // absolute(seat1, 7)  = (13 + 7)  mod 52 = 20
        // absolute(seat3, 33) = (39 + 33) mod 52 = 20
        expect(safeSquares.contains(20), isFalse);
        final state = buildAwaitMove(
          seats: fourPlayerSeats,
          roll: 1,
          currentSeat: 1,
          tokens: const {
            1: <int>[6, -1, -1, -1],
            3: <int>[33, -1, -1, -1],
          },
        );
        final result = apply(state, const MoveIntention(1, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.tokens[1][0], 7);
        expect(applied.state.tokens[3][0], -1);
        expect(applied.events.whereType<Captured>(), hasLength(1));
      },
    );
  });
}
