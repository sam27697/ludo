// docs/RULES.md rule 28a, with blocks: false, the live rules since
// 2026-10-15: two tokens of one seat on a square are a shelter, never a
// wall. docs/PROTOCOL.md section 4 (the blocks paragraph) says the server
// creates every room this way and ignores the wire blocks value; the engine
// itself is unchanged, this file proves the existing blocks: false
// behaviour against the restated rule.
//
// Cases 2, 3 and 8 of docs/RULES.md section 7 are restated here for the
// live rules; see the per-test note below for which ones
// test/rules/blocks_test.dart already proves with blocks: false.
//
// seat 0 has entry offset 0 (progress equals absolute square). seat 2 has
// entry offset 26, so seat 2 progress p sits at absolute (26 + p) mod 52.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test(
    'P1: a token passes over an opponent pair on a non-safe square: legal, '
    'lands beyond, pair untouched. Already proved by '
    'test/rules/blocks_test.dart, "a move whose path crosses what would be '
    'an opponent block with blocks on is legal and applies with blocks off" '
    '(the blocks: false arm); restated here for the live-rules file',
    () {
      // seat 0 pair at absolute 10 (not a safe square). seat 2 moves from
      // absolute 7 (progress 33) to absolute 12 (progress 38) on a roll of
      // 5: path 8, 9, 10, 11, 12, crossing the pair strictly between origin
      // and destination.
      expect(safeSquares.contains(10), isFalse);
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        blocks: false,
        tokens: const {
          0: <int>[10, 10, -1, -1],
          2: <int>[33, -1, -1, -1],
        },
      );
      expect(legalTokens(state), contains(0));
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[2][0], 38, reason: 'lands beyond the pair');
      expect(
        applied.state.tokens[0],
        containsAllInOrder(<int>[10, 10]),
        reason: 'the pair is merely passed over, never touched',
      );
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'P2: a token lands exactly on an opponent pair on a non-safe square: '
    'legal, no Captured event, all three tokens on that square. Already '
    'proved by test/rules/blocks_test.dart, "landing exactly on a square '
    'holding two tokens of one opponent seat is legal with blocks off and '
    'captures nothing (rule 28a)"; restated here for the live-rules file',
    () {
      // seat 0 pair at absolute 20 (not a safe square). seat 2 moves from
      // absolute 15 (progress 41) to absolute 20 (progress 46) on a roll
      // of 5, landing exactly on the pair.
      expect(safeSquares.contains(20), isFalse);
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        blocks: false,
        tokens: const {
          0: <int>[20, 20, -1, -1],
          2: <int>[41, -1, -1, -1],
        },
      );
      expect(legalTokens(state), contains(0));
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(
        applied.state.tokens[2][0],
        46,
        reason: 'the arriving token stands on the square',
      );
      expect(
        applied.state.tokens[0],
        containsAllInOrder(<int>[20, 20]),
        reason: 'both opponent tokens remain standing, rule 28a',
      );
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'P3: a token lands on a single opponent token on a non-safe square: '
    'that token is captured (control for P2, same destination square, one '
    'token instead of a pair)',
    () {
      // Same destination (absolute 20) as P2, but seat 0 has only one token
      // there, so rule 27 applies and it is captured.
      expect(safeSquares.contains(20), isFalse);
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        blocks: false,
        tokens: const {
          0: <int>[20, -1, -1, -1],
          2: <int>[41, -1, -1, -1],
        },
      );
      expect(legalTokens(state), contains(0));
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[2][0], 46);
      expect(
        applied.state.tokens[0][0],
        -1,
        reason: 'exactly one opponent token on the destination is a '
            'capture, rule 27; this is the control that proves P2 is not '
            'merely "captures never happen with blocks off"',
      );
      expect(applied.events.whereType<Captured>(), hasLength(1));
    },
  );

  test(
    'P4: leaving the yard onto an entry square holding an opponent pair is '
    'legal, because entry squares are safe (rule 1.3); nothing is captured',
    () {
      // seat 0's entry square is absolute 0. seat 2 progress 26 sits there:
      // (26 + 26) mod 52 = 0. Two seat 2 tokens form a pair on it.
      expect(safeSquares.contains(0), isTrue);
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        blocks: false,
        tokens: const {
          0: <int>[-1, 57, 57, 57],
          2: <int>[26, 26, -1, -1],
        },
      );
      expect(legalTokens(state), contains(0));
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 0);
      expect(
        applied.state.tokens[2],
        containsAllInOrder(<int>[26, 26]),
        reason: 'the pair on the safe entry square is untouched',
      );
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'P5: an opponent pair does not reduce the legal move set with blocks '
    'off, even on a position where blocks on removes the move entirely '
    '(the arm that is supposed to fail is run and checked)',
    () {
      // Same geometry as P1: seat 0 pair at absolute 10, seat 2 moving
      // absolute 7 -> 12 (progress 33 -> 38) on a roll of 5, path 8-12.
      final blocksOn = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        blocks: true,
        tokens: const {
          0: <int>[10, 10, -1, -1],
          2: <int>[33, -1, -1, -1],
        },
      );
      expect(
        legalTokens(blocksOn),
        isEmpty,
        reason: 'with blocks on, the pair at absolute 10 removes the only '
            'legal move for this fixture',
      );
      final onResult = apply(blocksOn, const MoveIntention(2, 0));
      expect(onResult, isA<Rejected>());
      expect((onResult as Rejected).error, EngineError.illegalMove);

      final blocksOff = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        blocks: false,
        tokens: const {
          0: <int>[10, 10, -1, -1],
          2: <int>[33, -1, -1, -1],
        },
      );
      expect(
        legalTokens(blocksOff),
        const <int>[0],
        reason: 'with blocks off, the same pair does not reduce the legal '
            'set at all',
      );
      final offResult = apply(blocksOff, const MoveIntention(2, 0));
      expect(offResult, isA<Applied>());
      expect((offResult as Applied).state.tokens[2][0], 38);
    },
  );
}
