// docs/RULES.md section 7: "The cases that must be tested explicitly." Each
// numbered case there gets exactly one test here, named for its number and
// its rule, so a reviewer can read section 7 with this file open beside it.
//
// seat 0 has entry offset 0 (progress equals absolute square). seat 2 has
// entry offset 26, so seat 2 progress p sits at absolute (26 + p) mod 52.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test(
    'case 1: landing on a safe square occupied by one opponent token '
    'captures nothing and leaves both tokens standing (rule 29)',
    () {
      expect(safeSquares.contains(34), isTrue);
      // seat 0 moves absolute 31 -> 34 (safe). seat 2 progress 8 sits at
      // absolute (26 + 8) mod 52 = 34, alone.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        currentSeat: 0,
        tokens: const {
          0: <int>[31, -1, -1, -1],
          2: <int>[8, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 34);
      expect(applied.state.tokens[2][0], 8);
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    'case 2: a move whose path crosses an opponent block is rejected, and '
    'the same move is accepted after the block is reduced to one token '
    '(rules 22, 23)',
    () {
      // seat 0 has (a block of) tokens at absolute 15. seat 2 moves
      // absolute 12 -> 17 (progress 38 -> 43), crossing 15.
      final blocked = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        tokens: const {
          0: <int>[15, 15, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final blockedResult = apply(blocked, const MoveIntention(2, 0));
      expect(blockedResult, isA<Rejected>());
      expect((blockedResult as Rejected).error, EngineError.illegalMove);

      final reduced = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        tokens: const {
          0: <int>[15, -1, -1, -1],
          2: <int>[38, -1, -1, -1],
        },
      );
      final reducedResult = apply(reduced, const MoveIntention(2, 0));
      expect(reducedResult, isA<Applied>());
      expect((reducedResult as Applied).state.tokens[2][0], 43);
    },
  );

  test(
    'case 3: a move that lands exactly on an opponent block is rejected, '
    'not treated as a capture (rule 28)',
    () {
      // seat 0 block at absolute 15. seat 2 moves absolute 10 -> 15
      // (progress 36 -> 41), landing exactly on it.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 2,
        tokens: const {
          0: <int>[15, 15, -1, -1],
          2: <int>[36, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(2, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    },
  );

  test(
    'case 4: three consecutive 6s forfeit the turn and the third 6'
    "'s move is not applied (rule 10)",
    () {
      // sixes = 2 models the first two 6s already applied this turn.
      // token 0 sits at 30, where 30 + 6 = 36 would otherwise be a
      // perfectly ordinary legal advance: first confirm that as a sanity
      // check, so "not applied" below cannot be standing in for "was
      // illegal anyway" (an overshoot, a block, and so on). Tokens 1, 2
      // and 3 are in the yard, and rule 17 lets every yard token out on a
      // roll of 6, so the legal set is not just token 0 -- the sanity
      // check only needs token 0 to be among it.
      final sanity = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 2,
        currentSeat: 0,
        tokens: const {
          0: <int>[30, -1, -1, -1],
        },
      );
      expect(legalTokens(sanity), contains(0));

      // Now the third 6 itself: the roll step must recognise sixes == 2
      // and a face of 6 before it ever computes a legal set, and must
      // forfeit the turn without offering a move.
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        sixes: 2,
        rngState: 1,
        tokens: const {
          0: <int>[30, -1, -1, -1],
        },
      );
      final result = apply(state, const RollIntention(0, 6));
      expect(result, isA<Applied>());
      final applied = result as Applied;

      expect(applied.events.whereType<Moved>(), isEmpty);
      expect(
        applied.events,
        equals(<Object?>[
          isA<Rolled>().having((e) => e.value, 'value', 6),
          isA<TurnEnded>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.reason, 'reason', TurnEndReason.threeSixes),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(
        applied.state.tokens[0][0],
        30,
        reason: 'the move the third 6 would have allowed is not made',
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(applied.state.sixes, 0);
    },
  );

  test(
    'case 5: overshooting home is illegal: a token at progress 55 rolling '
    '4 has no legal move for that token (rule 19)',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 4,
        currentSeat: 0,
        tokens: const {
          0: <int>[55, -1, -1, -1],
        },
      );
      expect(legalTokens(state), isNot(contains(0)));
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    },
  );

  test(
    'case 6: a roll producing no legal move for any token passes the turn '
    'immediately, with no timer and no error (rule 7)',
    () {
      // Three tokens home and one in the yard: any face that is not a 6
      // leaves nothing legal.
      final state = buildAwaitRoll(
        seats: twoPlayerSeats,
        currentSeat: 0,
        rngState: 1,
        tokens: const {
          0: <int>[-1, 57, 57, 57],
        },
      );
      final result = apply(state, const RollIntention(0, 5));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(
        applied.events,
        equals(<Object?>[
          isA<Rolled>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.value, 'value', 5)
              .having((e) => e.legal, 'legal', isEmpty),
          isA<TurnEnded>()
              .having((e) => e.seat, 'seat', 0)
              .having((e) => e.reason, 'reason', TurnEndReason.noLegalMove),
          isA<TurnBegan>().having((e) => e.seat, 'seat', 2),
        ]),
      );
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 2);
      expect(applied.state.tokens[0][0], -1, reason: 'no move was played');
    },
  );

  test(
    'case 7: a 6 rolled when every token is already out of the yard still '
    'grants an extra roll and does not force a yard exit (rules 9, 17)',
    () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[10, 20, 30, 40],
        },
      );
      expect(
        state.tokens[0],
        everyElement(isNot(-1)),
        reason: 'no token is in the yard to force an exit',
      );
      expect(legalTokens(state), const <int>[0, 1, 2, 3]);
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 16,
          reason: 'advances by 6, no yard exit involved');
      expect(applied.events.whereType<ExtraRoll>(), hasLength(1));
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
    },
  );

  test(
    "case 8: a seat's own tokens stacking is legal and forms a block, and "
    "the seat's other tokens still pass it (rules 24, 30)",
    () {
      final stacking = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 2,
        currentSeat: 0,
        tokens: const {
          0: <int>[18, 20, -1, -1],
        },
      );
      final stackResult = apply(stacking, const MoveIntention(0, 0));
      expect(stackResult, isA<Applied>());
      expect((stackResult as Applied).state.tokens[0],
          const <int>[20, 20, -1, -1]);
      expect(stackResult.events.whereType<Captured>(), isEmpty);

      final passingOwnStack = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[20, 20, 15, -1],
        },
      );
      final passResult = apply(passingOwnStack, const MoveIntention(0, 2));
      expect(passResult, isA<Applied>());
      expect((passResult as Applied).state.tokens[0][2], 21);
    },
  );

  test(
    'case 9: two tokens reaching home on consecutive rolls of one turn, '
    'the second one winning the game, terminates the game at the correct '
    'moment (rules 33, 35)',
    () {
      // First move of the turn: the third token reaches home on a roll of
      // 6, which grants an extra roll rather than a win, because the
      // fourth token is still on the board.
      final firstMove = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 51, 53],
        },
      );
      final firstResult = apply(firstMove, const MoveIntention(0, 2));
      expect(firstResult, isA<Applied>());
      final afterFirst = firstResult as Applied;
      expect(afterFirst.state.tokens[0], const <int>[57, 57, 57, 53]);
      expect(afterFirst.state.winner, isNull);
      expect(afterFirst.state.phase, GamePhase.awaitRoll);
      expect(afterFirst.state.currentSeat, 0);
      expect(
        afterFirst.events,
        equals(<Object?>[isA<Moved>(), isA<TokenHome>(), isA<ExtraRoll>()]),
      );

      // Second move of the same turn (the extra roll drew a 4): the fourth
      // token reaches home too, and the game ends right there.
      final secondMove = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 4,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[57, 57, 57, 53],
        },
      );
      final secondResult = apply(secondMove, const MoveIntention(0, 3));
      expect(secondResult, isA<Applied>());
      final afterSecond = secondResult as Applied;
      expect(afterSecond.state.tokens[0], const <int>[57, 57, 57, 57]);
      expect(afterSecond.state.winner, 0);
      expect(afterSecond.state.phase, GamePhase.finished);
      expect(
        afterSecond.events,
        equals(<Object?>[isA<Moved>(), isA<TokenHome>(), isA<GameWon>()]),
      );
    },
  );

  test(
    'case 10: a capture on the last legal move grants an extra roll even '
    'though the capture also emptied the board of that seat'
    "'s reachable targets (rule 11)",
    () {
      // seat 0 token 3 at absolute 40 is the only token this roll can move
      // (the other three are in the yard and this roll is not a 6).
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 5,
        currentSeat: 0,
        captureBonus: true,
        tokens: const {
          0: <int>[-1, -1, -1, 40],
          2: <int>[19, -1, -1, -1], // absolute (26 + 19) mod 52 = 45
        },
      );
      expect(
        legalTokens(state),
        const <int>[3],
        reason: 'this must be the only legal move for the fixture to prove '
            'the case',
      );
      final result = apply(state, const MoveIntention(0, 3));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][3], 45);
      expect(applied.state.tokens[2][0], -1);
      expect(applied.events.whereType<Captured>(), hasLength(1));
      expect(applied.events.whereType<ExtraRoll>(), hasLength(1));
      expect(applied.state.phase, GamePhase.awaitRoll);
      expect(applied.state.currentSeat, 0);
    },
  );

  test(
    'case 11: a token leaving the yard onto its entry square that holds '
    'one opponent token captures nothing, because the entry square is '
    'safe by rule 1.3',
    () {
      expect(safeSquares.contains(0), isTrue);
      // seat 2 progress 26 sits at absolute (26 + 26) mod 52 = 0, seat 0's
      // entry square.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[-1, 57, 57, 57],
          2: <int>[26, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 0);
      expect(applied.state.tokens[2][0], 26);
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );

  test(
    "case 12: passing over an opponent's single token does not capture it "
    '(rule 31)',
    () {
      // seat 0 moves absolute 2 -> 8. seat 2 progress 31 sits at absolute
      // (26 + 31) mod 52 = 5, strictly inside that path.
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 6,
        sixes: 1,
        currentSeat: 0,
        tokens: const {
          0: <int>[2, -1, -1, -1],
          2: <int>[31, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Applied>());
      final applied = result as Applied;
      expect(applied.state.tokens[0][0], 8);
      expect(applied.state.tokens[2][0], 31);
      expect(applied.events.whereType<Captured>(), isEmpty);
    },
  );
}
