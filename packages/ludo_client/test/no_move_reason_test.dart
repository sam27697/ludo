// Conformance tests for work/ludo/orders/C-474-why-no-move.md, D1: the pure
// function that says why a roll had no move. Written from the contract text
// alone; the implementation is built in parallel in a tree this file's
// author has not read.
//
// The contract, restated so each hand-worked answer below can be checked:
//
//   F = the faces of the roll (non-empty for a real answer).
//   U = my unfinished tokens: every progress that is not 57.
//   In order, the first rule that holds:
//     1. needSix:   U not empty, every token in U is in the yard (-1), and
//                   no face in F is 6.
//     2. needExact: U not empty, no token in U is in the yard, and for every
//                   face f in F and every token p in U, p + f > 57.
//     3. plain:     anything else.
//   An empty `faces` answers plain.
//
// Every case names its contract id, works the answer out in a comment above
// the expect, and says in one line the realistic mistake it catches. On
// today's main the import below does not resolve, so the file fails to
// compile: expected until the implementation lands.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/no_move_reason.dart';

/// Failure text: the scenario, what the contract says, what came back.
String _why(
  String scenario,
  NoMoveReason expected,
  List<int> tokens,
  List<int> faces,
) =>
    'C-474 D1 scenario "$scenario": noMoveReason(myTokens: $tokens, '
    'faces: $faces) must be $expected (see the hand-worked comment above this '
    'expect in test/no_move_reason_test.dart)';

void _check(
  String scenario,
  List<int> tokens,
  List<int> faces,
  NoMoveReason expected,
) {
  final NoMoveReason got = noMoveReason(myTokens: tokens, faces: faces);
  expect(got, expected, reason: _why(scenario, expected, tokens, faces));
}

void main() {
  group('D1: the enum', () {
    // Catches an enum with a fourth member or a renamed one: the screen
    // switches on exactly these three.
    test('C-474 D1: NoMoveReason has exactly needSix, needExact, plain', () {
      // The contract declares
      //   enum NoMoveReason { needSix, needExact, plain }
      // so values, in order, are those three.
      expect(NoMoveReason.values, <NoMoveReason>[
        NoMoveReason.needSix,
        NoMoveReason.needExact,
        NoMoveReason.plain,
      ], reason: 'C-474 D1 declares exactly three members in this order');
    });
  });

  group('D1.1 NEED_SIX', () {
    // Catches a rule that wants a token on the board before it explains
    // anything: the first-time player with four tokens in the yard is the
    // very case X92 was filed for.
    test('C-474 D1.1: four in the yard and a 3 is needSix', () {
      // tokens [-1,-1,-1,-1]: none is 57, so U = {-1,-1,-1,-1}, not empty.
      // Every token in U is -1 (the yard). F = {3}, no 6 in F.
      // Rule 1 holds first: needSix.
      _check(
        'four in the yard, a 3',
        const <int>[-1, -1, -1, -1],
        const <int>[3],
        NoMoveReason.needSix,
      );
    });

    // Catches counting a finished token as "not in the yard", which would
    // break "every token in U is in the yard" for a player with one home.
    test('C-474 D1.1: three in the yard and one finished, a 5 is needSix', () {
      // tokens [-1,-1,-1,57]: 57 is finished, so U = {-1,-1,-1} (the
      // finished token is not in U). U is not empty, every token in U is
      // -1, F = {5} has no 6. Rule 1 holds first: needSix.
      _check(
        'three in the yard, one finished, a 5',
        const <int>[-1, -1, -1, 57],
        const <int>[5],
        NoMoveReason.needSix,
      );
    });

    // Catches a finished-token filter that only looks at the last slot.
    test('C-474 D1.1: the finished token may sit in any slot', () {
      // tokens [57,-1,-1,-1]: U = {-1,-1,-1}, all in the yard; F = {1}, no
      // 6. Rule 1 holds: needSix.
      _check(
        'finished token first, a 1',
        const <int>[57, -1, -1, -1],
        const <int>[1],
        NoMoveReason.needSix,
      );
    });

    // Catches a filter that drops everything that is not -1 instead of
    // dropping only 57: two finished tokens still leave a yard-only U.
    test('C-474 D1.1: one in the yard and three finished, a 2 is needSix', () {
      // tokens [57,57,57,-1]: U = {-1}; the single token is in the yard;
      // F = {2}, no 6. Rule 1 holds: needSix.
      _check(
        'one in the yard, three finished, a 2',
        const <int>[57, 57, 57, -1],
        const <int>[2],
        NoMoveReason.needSix,
      );
    });

    // Catches reading the queue as "first face only": every face must be
    // checked for a 6, and repeats of a non-6 change nothing.
    test('C-474 D1.1: a queue of two 3s and a 1 with all in the yard', () {
      // tokens all -1: U all in the yard. F = {3,3,1}, no 6 anywhere.
      // Rule 1 holds: needSix.
      _check(
        'four in the yard, queue [3, 3, 1]',
        const <int>[-1, -1, -1, -1],
        const <int>[3, 3, 1],
        NoMoveReason.needSix,
      );
    });

    // Catches a token at progress 0 (on its start square) being treated as
    // "in the yard": only -1 is the yard.
    test('C-474 D1.1: a token at 0 is on the board, so not needSix', () {
      // tokens [0,-1,-1,-1]: U = {0,-1,-1,-1}. Rule 1 needs every token in
      // U in the yard; the 0 is not. Rule 2 needs no token in U in the yard;
      // three are. So rule 3: plain.
      _check(
        'one on the start square, three in the yard, a 3',
        const <int>[0, -1, -1, -1],
        const <int>[3],
        NoMoveReason.plain,
      );
    });
  });

  group('D1.1 not NEED_SIX when a 6 is in F', () {
    // Catches testing only the first face of the queue (6 here is first)
    // or testing the wrong direction: with a 6 in F the "you need a 6" line
    // would be false, a 6 was in hand.
    test('C-474 D1.1: queue [6, 6, 3] with all in the yard is not needSix', () {
      // tokens all -1: U all in the yard. F = {6,6,3}; 6 is in F, so rule 1
      // fails. Rule 2 needs no token in the yard; all four are. So rule 3:
      // plain.
      _check(
        'four in the yard, queue [6, 6, 3]',
        const <int>[-1, -1, -1, -1],
        const <int>[6, 6, 3],
        NoMoveReason.plain,
      );
    });

    // Catches checking only the first face or only the last: a 6 in the
    // middle of the queue still defeats rule 1.
    test('C-474 D1.1: a 6 last or in the middle also defeats needSix', () {
      // tokens all -1. F = {3,6}: 6 present, rule 1 fails, rule 2 fails
      // (tokens in the yard), so plain.
      _check(
        'four in the yard, queue [3, 6]',
        const <int>[-1, -1, -1, -1],
        const <int>[3, 6],
        NoMoveReason.plain,
      );
      // F = {2,6,4}: same reasoning, plain.
      _check(
        'four in the yard, queue [2, 6, 4]',
        const <int>[-1, -1, -1, -1],
        const <int>[2, 6, 4],
        NoMoveReason.plain,
      );
    });

    // Catches the single-face roll of a 6 with the board blocked or
    // otherwise unmoved: a 6 is never "you need a 6".
    test('C-474 D1.1: a lone 6 with all in the yard is not needSix', () {
      // tokens all -1, F = {6}: 6 is in F, rule 1 fails; rule 2 fails (yard
      // tokens); plain.
      _check(
        'four in the yard, a 6',
        const <int>[-1, -1, -1, -1],
        const <int>[6],
        NoMoveReason.plain,
      );
    });
  });

  group('D1.2 NEED_EXACT', () {
    // Catches a rule that only handles the last token home: 55 + 4 = 59 is
    // past 57 and the three finished tokens must not count.
    test('C-474 D1.2: one at 55 and three at 57, a 4 is needExact', () {
      // tokens [55,57,57,57]: U = {55}. Rule 1: 55 is not in the yard, so it
      // fails. Rule 2: U not empty, no token in U in the yard, and 55 + 4 =
      // 59 > 57 for the only (face, token) pair. Rule 2 holds: needExact.
      _check(
        'one at 55, three finished, a 4',
        const <int>[55, 57, 57, 57],
        const <int>[4],
        NoMoveReason.needExact,
      );
    });

    // Catches checking only the first unfinished token: both must overshoot.
    test('C-474 D1.2: tokens at 54 and 56 with a 4 are needExact', () {
      // tokens [54,56,57,57]: U = {54,56}. Rule 1 fails (not in the yard).
      // Rule 2: 54 + 4 = 58 > 57 and 56 + 4 = 60 > 57, for every pair.
      // Rule 2 holds: needExact.
      _check(
        'tokens at 54 and 56, two finished, a 4',
        const <int>[54, 56, 57, 57],
        const <int>[4],
        NoMoveReason.needExact,
      );
    });

    // Catches an off-by-one at the finish: p + f == 57 lands exactly home
    // and is a legal move, so the roll is not an overshoot.
    test('C-474 D1.2: 53 + 4 = 57 fits exactly, so it is not needExact', () {
      // tokens [53,57,57,57]: U = {53}. Rule 1 fails. Rule 2 needs 53 + 4 >
      // 57, but 57 > 57 is false, so rule 2 fails. Rule 3: plain.
      _check(
        'one at 53, three finished, a 4 (lands on 57)',
        const <int>[53, 57, 57, 57],
        const <int>[4],
        NoMoveReason.plain,
      );
    });

    // Catches the other side of the same off-by-one: 58 is past home.
    test('C-474 D1.2: 53 + 5 = 58 overshoots, so it is needExact', () {
      // tokens [53,57,57,57]: U = {53}. Rule 2: 53 + 5 = 58 > 57 holds for
      // the only pair. needExact.
      _check(
        'one at 53, three finished, a 5 (lands on 58)',
        const <int>[53, 57, 57, 57],
        const <int>[5],
        NoMoveReason.needExact,
      );
    });

    // Catches checking only the first face of a queue: every face must
    // overshoot every token.
    test('C-474 D1.2: queue [4, 5] with a token at 55 is needExact', () {
      // tokens [55,57,57,57]: U = {55}. 55 + 4 = 59 > 57 and 55 + 5 = 60 >
      // 57: every pair overshoots. Rule 2 holds: needExact.
      _check(
        'one at 55, queue [4, 5]',
        const <int>[55, 57, 57, 57],
        const <int>[4, 5],
        NoMoveReason.needExact,
      );
    });

    // Catches a finished token (57) being treated as unfinished: 57 + 1 =
    // 58 would then overshoot and hide a real mix; here it must not matter,
    // and the one real token at 56 with a 2 does overshoot.
    test('C-474 D1.2: finished tokens do not take part in the sum', () {
      // tokens [57,57,57,56]: U = {56}. 56 + 2 = 58 > 57. Rule 2 holds:
      // needExact.
      _check(
        'finished tokens first, one at 56, a 2',
        const <int>[57, 57, 57, 56],
        const <int>[2],
        NoMoveReason.needExact,
      );
    });
  });

  group('D1.2 not NEED_EXACT when one of the faces fits', () {
    // Catches "any face overshoots" in place of "every face overshoots":
    // F = {4, 1}, the 1 takes 56 home, so the player had a move and this is
    // not a no-move of the exact-number kind.
    test('C-474 D1.2: F = {4, 1} with a token at 56 is not needExact', () {
      // tokens [56,57,57,57]: U = {56}. Rule 1 fails (not in the yard).
      // Rule 2 needs p + f > 57 for every pair: 56 + 4 = 60 > 57 holds, but
      // 56 + 1 = 57 > 57 does not. Rule 2 fails. Rule 3: plain.
      _check(
        'one at 56, queue [4, 1]',
        const <int>[56, 57, 57, 57],
        const <int>[4, 1],
        NoMoveReason.plain,
      );
    });

    // Catches "every token overshoots" in place of "every token overshoots
    // every face": here one token (50) fits the 4, one (55) does not.
    test('C-474 D1.2: one token that fits makes it not needExact', () {
      // tokens [55,50,57,57]: U = {55,50}. 55 + 4 = 59 > 57 holds, but
      // 50 + 4 = 54 > 57 does not. Rule 2 fails; rule 1 fails. plain.
      _check(
        'tokens at 55 and 50, a 4',
        const <int>[55, 50, 57, 57],
        const <int>[4],
        NoMoveReason.plain,
      );
    });
  });

  group('D1.3 PLAIN', () {
    // Catches a rule 1 that fires when only some of U is in the yard, which
    // would tell a player with a token on the board that a 6 is the problem.
    test('C-474 D1.3: one in the yard, one at 55, a 4 is plain', () {
      // tokens [-1,55,57,57]: U = {-1,55}. Rule 1: not every token in U is
      // in the yard (55 is not), so it fails. Rule 2: a token in U is in the
      // yard (-1), so it fails. Rule 3: plain.
      _check(
        'one in the yard, one at 55, two finished, a 4',
        const <int>[-1, 55, 57, 57],
        const <int>[4],
        NoMoveReason.plain,
      );
    });

    // Catches a rule that reads an empty U as "all of U is in the yard"
    // (vacuous truth) and tells a player who has won every token to roll a
    // 6, or as "no yard token and nothing fits" and says the exact number.
    test('C-474 D1.3: all four finished (U empty) is plain', () {
      // tokens [57,57,57,57]: U = {}. Rule 1 and rule 2 both need U not
      // empty, so both fail. Rule 3: plain.
      _check(
        'four finished, a 3',
        const <int>[57, 57, 57, 57],
        const <int>[3],
        NoMoveReason.plain,
      );
    });

    // Catches a function that indexes faces.first (a crash) or treats no
    // faces as "no 6 in F" (vacuously needSix): the contract says an empty
    // list answers plain.
    test('C-474 D1.3: an empty faces list is plain, whatever the tokens', () {
      // faces = {} is explicitly plain ("An empty faces answers plain"),
      // checked against a board that would be needSix with a face.
      _check(
        'empty faces, four in the yard',
        const <int>[-1, -1, -1, -1],
        const <int>[],
        NoMoveReason.plain,
      );
      // ... and against a board that would be needExact with a face: with
      // F empty, "for every face" is vacuously true, which is the trap.
      _check(
        'empty faces, one at 55 and three finished',
        const <int>[55, 57, 57, 57],
        const <int>[],
        NoMoveReason.plain,
      );
      // ... and against all finished.
      _check(
        'empty faces, four finished',
        const <int>[57, 57, 57, 57],
        const <int>[],
        NoMoveReason.plain,
      );
    });

    // Catches rule 2 applying while a yard token exists with another token
    // at 56: a token in the yard needs a 6, not an exact number.
    test('C-474 D1.3: a yard token and a token at 56, a 2 is plain', () {
      // tokens [-1,56,57,57]: U = {-1,56}. Rule 1 fails (56 is not in the
      // yard). Rule 2 fails (-1 is in the yard). plain.
      _check(
        'one in the yard, one at 56, a 2',
        const <int>[-1, 56, 57, 57],
        const <int>[2],
        NoMoveReason.plain,
      );
    });

    // Catches a token on the track that is simply blocked (neither rule is
    // about blocks): a token at 10 with a 3 overshoots nothing and is not
    // in the yard.
    test('C-474 D1.3: a mid-track token that overshoots nothing is plain', () {
      // tokens [10,57,57,57]: U = {10}. Rule 1 fails. Rule 2: 10 + 3 = 13 >
      // 57 is false. plain (e.g. a block stopped the move).
      _check(
        'one at 10, three finished, a 3',
        const <int>[10, 57, 57, 57],
        const <int>[3],
        NoMoveReason.plain,
      );
    });

    // Catches a yard token plus a mid-track token, the common "blocked and
    // waiting for a 6" mix, being collapsed into needSix.
    test('C-474 D1.3: three in the yard and one at 10, a 2 is plain', () {
      // tokens [-1,-1,-1,10]: U = {-1,-1,-1,10}. Rule 1 fails (10 is not in
      // the yard). Rule 2 fails (tokens in the yard). plain.
      _check(
        'three in the yard, one at 10, a 2',
        const <int>[-1, -1, -1, 10],
        const <int>[2],
        NoMoveReason.plain,
      );
    });
  });

  group('purity', () {
    // Catches an implementation that sorts, removes finished tokens from,
    // or otherwise mutates the caller's lists: the screen passes its live
    // snapshot lists in.
    test('C-474 D1: the inputs are not modified', () {
      final List<int> tokens = <int>[57, -1, -1, -1];
      final List<int> faces = <int>[3, 6, 1];
      final NoMoveReason first = noMoveReason(myTokens: tokens, faces: faces);
      // tokens [57,-1,-1,-1], faces {3,6,1}: U = {-1,-1,-1}, 6 in F, so rule
      // 1 fails; rule 2 fails (yard tokens); plain.
      expect(
        first,
        NoMoveReason.plain,
        reason: _why('purity, first call', NoMoveReason.plain, tokens, faces),
      );
      expect(tokens, <int>[
        57,
        -1,
        -1,
        -1,
      ], reason: 'C-474 D1: noMoveReason must not modify myTokens');
      expect(faces, <int>[
        3,
        6,
        1,
      ], reason: 'C-474 D1: noMoveReason must not modify faces');
      // The same call twice gives the same answer.
      expect(
        noMoveReason(myTokens: tokens, faces: faces),
        first,
        reason: 'C-474 D1: noMoveReason must be a pure function',
      );
    });
  });
}
