// docs/RULES.md section 4.1, rules 21-26: blocks.
//
// seat 0 has entry offset 0, so its progress values equal absolute track
// squares directly, which keeps the arithmetic in these fixtures honest.
// seat 2 has entry offset 26, so seat 2 progress p sits at absolute square
// (26 + p) mod 52; every seat-2 fixture below is computed from that.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group(
      'rules 21 and 22: two or more same-seat tokens form a block that '
      'stops an opponent', () {
    test(
      'a move whose path crosses a square holding an opponent block is '
      'illegal',
      () {
        // seat 0 block at absolute 15. seat 2 moves from absolute 12 to
        // absolute 17 (progress 38 -> 43), a path of 13,14,15,16,17, which
        // crosses the block strictly between origin and destination.
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 5,
          currentSeat: 2,
          tokens: const {
            0: <int>[15, 15, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );
        expect(legalTokens(state), isEmpty);
        final result = apply(state, const MoveIntention(2, 0));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.illegalMove);
      },
    );

    test('a move that lands exactly on an opponent block is illegal', () {
      // seat 2 moves from absolute 10 (progress 36) to absolute 15
      // (progress 41), landing exactly on the block.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        tokens: const {
          0: <int>[15, 15, -1, -1],
          2: <int>[36, -1, -1, -1],
        },
      );
      expect(legalTokens(state), isEmpty);
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    });

    test(
      'a block behind the token, already passed this lap, does not '
      'obstruct it',
      () {
        // seat 0 block at absolute 15, equivalent to seat 2 progress 41.
        // seat 2 moves from progress 45 to 48, both already past 41.
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 3,
          currentSeat: 2,
          tokens: const {
            0: <int>[15, 15, -1, -1],
            2: <int>[45, -1, -1, -1],
          },
        );
        expect(legalTokens(state), contains(0));
        final result = apply(state, const MoveIntention(2, 0));
        expect(result, isA<Applied>());
        expect((result as Applied).state.tokens[2][0], 48);
      },
    );

    test(
      'a single opponent token, not a block, does not obstruct the path '
      'and is not captured by passing over it',
      () {
        // Same geometry as the "crosses a block" case above, but seat 0
        // has only one token on absolute 15, so it is not a block
        // (rule 28) and rule 31 says passing over it never captures it.
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 5,
          currentSeat: 2,
          tokens: const {
            0: <int>[15, -1, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );
        expect(legalTokens(state), contains(0));
        final result = apply(state, const MoveIntention(2, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.tokens[2][0], 43);
        expect(
          applied.state.tokens[0][0],
          15,
          reason: 'a token merely passed over is never captured',
        );
        expect(applied.events.whereType<Captured>(), isEmpty);
      },
    );
  });

  group(
      'rule 23: path is every square strictly between origin and '
      'destination, plus the destination; a yard exit has a path of '
      'exactly its entry square', () {
    test('a block on the entry square blocks a yard exit', () {
      // seat 0 entry square is absolute 0. seat 2 progress 26 sits there:
      // (26 + 26) mod 52 = 0.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[-1, 57, 57, 57],
          2: <int>[26, 26, -1, -1],
        },
      );
      expect(legalTokens(state), isEmpty);
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    });

    test(
      'a block elsewhere on the board does not affect a yard exit, '
      'because the yard-exit path is only the entry square',
      () {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 6,
          sixes: 1,
          currentSeat: 0,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
            2: <int>[41, 41, -1, -1], // absolute 15, nowhere near entry 0
          },
        );
        expect(legalTokens(state), const <int>[0]);
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Applied>());
        expect((result as Applied).state.tokens[0][0], 0);
      },
    );
  });

  test(
    'rule 24: a block does not obstruct its own owner; the seat'
    "'s own tokens pass and stack on their own block freely",
    () {
      final passingThrough = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        tokens: const {
          0: <int>[10, 10, 5, -1],
        },
      );
      expect(legalTokens(passingThrough), contains(2));
      final passResult = apply(passingThrough, const MoveIntention(0, 2));
      expect(passResult, isA<Applied>());
      expect((passResult as Applied).state.tokens[0][2], 11);

      final landingOnIt = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        tokens: const {
          0: <int>[10, 10, 4, -1],
        },
      );
      expect(legalTokens(landingOnIt), contains(2));
      final landResult = apply(landingOnIt, const MoveIntention(0, 2));
      expect(landResult, isA<Applied>());
      final applied = landResult as Applied;
      expect(applied.state.tokens[0], containsAllInOrder(<int>[10, 10, 10]));
    },
  );

  test(
    'rule 25: a block is only meaningful on the main track; two of a '
    "seat's own tokens may share a home column cell",
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 1,
        tokens: const {
          0: <int>[53, 53, 52, -1],
        },
      );
      expect(legalTokens(state), contains(2));
      final result = apply(state, const MoveIntention(0, 2));
      expect(result, isA<Applied>());
      expect((result as Applied).state.tokens[0],
          containsAllInOrder(<int>[53, 53, 53]));
    },
  );

  test(
    'rule 26: a block on a safe square is both a block and safe; an '
    'opponent still cannot land on it',
    () {
      expect(safeSquares.contains(8), isTrue);
      // seat 0 block at absolute 8. seat 2 progress 34 sits there:
      // (26 + 34) mod 52 = 8.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 4,
        currentSeat: 2,
        tokens: const {
          0: <int>[8, 8, -1, -1],
          2: <int>[30, -1, -1, -1],
        },
      );
      expect(legalTokens(state), isEmpty);
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    },
  );

  group(
      'rule 21: with the blocks toggle off, a same-seat stack no longer '
      'obstructs anyone', () {
    test(
      'a move whose path crosses what would be an opponent block with '
      'blocks on is legal and applies with blocks off',
      () {
        // Same geometry as the "crosses a block" case above: seat 0 has
        // two tokens at absolute 15, seat 2 moves from absolute 12 to
        // absolute 17 (progress 38 -> 43), a path of 13,14,15,16,17.
        final blocksOn = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 5,
          currentSeat: 2,
          blocks: true,
          tokens: const {
            0: <int>[15, 15, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );
        expect(legalTokens(blocksOn), isEmpty);
        final onResult = apply(blocksOn, const MoveIntention(2, 0));
        expect(onResult, isA<Rejected>());
        expect((onResult as Rejected).error, EngineError.illegalMove);

        final blocksOff = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 5,
          currentSeat: 2,
          blocks: false,
          tokens: const {
            0: <int>[15, 15, -1, -1],
            2: <int>[38, -1, -1, -1],
          },
        );
        expect(legalTokens(blocksOff), contains(0));
        final offResult = apply(blocksOff, const MoveIntention(2, 0));
        expect(offResult, isA<Applied>());
        expect((offResult as Applied).state.tokens[2][0], 43);
      },
    );

    test(
      'landing exactly on a square holding two tokens of one opponent '
      'seat is legal with blocks off and captures nothing (rule 28a)',
      () {
        // seat 0 has two tokens at absolute 15. seat 2 moves from absolute
        // 10 (progress 36) to absolute 15 (progress 41), landing exactly
        // on the stack. With blocks off rule 22 never fires, and rule 28
        // still requires exactly one opponent token on the destination to
        // capture, so landing on two of them captures neither.
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 5,
          currentSeat: 2,
          blocks: false,
          tokens: const {
            0: <int>[15, 15, -1, -1],
            2: <int>[36, -1, -1, -1],
          },
        );
        expect(legalTokens(state), contains(0));
        final result = apply(state, const MoveIntention(2, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.tokens[2][0], 41,
            reason: 'the arriving token stands on the square');
        expect(
          applied.state.tokens[0],
          containsAllInOrder(<int>[15, 15]),
          reason: 'both opponent tokens remain standing, per rule 28a',
        );
        expect(applied.events.whereType<Captured>(), isEmpty);
      },
    );
  });
}
