// docs/RULES.md section 4.2, rules 27-32: capture.
//
// seat 0 has entry offset 0 (progress equals absolute square). seat 2 has
// entry offset 26, so seat 2 progress p sits at absolute (26 + p) mod 52.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test(
    'rule 27: a move that ends on a main track square holding exactly one '
    'opponent token sends it home',
    () {
      // seat 0 moves absolute 9 -> 12. seat 2 progress 38 sits at absolute
      // (26 + 38) mod 52 = 12, alone.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        captureBonus: false,
        tokens: const {
          0: <int>[9, -1, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 12);
      expect(applied.state.tokens[2][0], -1);
      final captured = applied.events.whereType<Captured>().single;
      expect(captured.seat, 2);
      expect(captured.token, 0);
      expect(captured.by, 0);
      expect(captured.byToken, 0);
    },
  );

  test(
    'rule 28: landing on two or more opponent tokens is a block, not a '
    'capture, and was already illegal under rule 22',
    () {
      // seat 0 moves absolute 27 -> 30. seat 2 progress 4 and 4 sit at
      // absolute (26 + 4) mod 52 = 30, a block of two.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[27, -1, -1, -1],
          2: <int>[4, 4, -1, -1],
        },
      );
      expect(legalTokens(state), isEmpty);
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    },
  );

  test(
    'rule 29: a capture cannot happen on a safe square; both tokens stand '
    'together',
    () {
      expect(safeSquares.contains(21), isTrue);
      // seat 0 moves absolute 18 -> 21 (safe). seat 2 progress 47 sits at
      // absolute (26 + 47) mod 52 = 21, alone.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[18, -1, -1, -1],
          2: <int>[47, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 21);
      expect(
        applied.state.tokens[2][0],
        47,
        reason:
            'landing on a safe square holding one opponent captures nothing',
      );
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'rule 30: a token can never capture its own seat; landing on your own '
    'token is legal and forms a block',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 2,
        currentSeat: 0,
        tokens: const {
          0: <int>[18, 20, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0], const <int>[20, 20, -1, -1]);
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'rule 31: capture is decided only by the destination square; a token '
    'passed over is never captured',
    () {
      // seat 0 moves absolute 5 -> 11. seat 2 progress 35 sits at absolute
      // (26 + 35) mod 52 = 9, strictly inside that path but not the
      // destination.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[5, -1, -1, -1],
          2: <int>[35, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 11);
      expect(applied.state.tokens[2][0], 35,
          reason: 'passed over, not landed on');
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test('rule 32: a capture grants another roll, per rule 11', () {
    // seat 0 moves absolute 40 -> 45. seat 2 progress 19 sits at absolute
    // (26 + 19) mod 52 = 45, alone.
    final state = buildAwaitMove(
      seats: twoPlayerSeats,
      roll: 5,
      currentSeat: 0,
      captureBonus: true,
      tokens: const {
        0: <int>[40, -1, -1, -1],
        2: <int>[19, -1, -1, -1],
      },
    );
    final result = apply(state, const MoveIntention(0, 0));
    expect(result, isA<Applied>());
    final applied = result as Applied;
    expect(applied.events.whereType<Captured>(), hasLength(1));
    expect(applied.events.whereType<ExtraRoll>(), hasLength(1));
    expect(applied.state.phase, GamePhase.awaitRoll);
    expect(applied.state.currentSeat, 0);
  });
}
