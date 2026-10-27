// Pure-function proof for C-471 D1 and D2: recommendMove picks the hint.
// Written from the contract (work/ludo/orders/C-471), not from any
// implementation. No widgets, no I/O.
//
// Reading a board. Progress values follow RULES.md 1.2: -1 is the yard, 0..51
// the main track, 52..56 the home column, 57 home. A seat's token at progress
// p on the main track stands on absolute square (13 * seat + p) % 52. Safe
// squares are 0, 8, 13, 21, 26, 34, 39 and 47. Every expected answer below is
// worked out by hand from the contract's definitions in the comment above its
// expect; nothing is computed by calling the function or by a copy of its
// logic.
//
// Fillers. A token that cannot move is parked in the yard (-1) on a roll that
// is not a 6, and at home (57) on a roll that is a 6, so a filler is never a
// candidate and never a neighbour on the track.
//
// A note on the q + d <= 51 edge. A threat at q + d == 52 would land on the
// victim's own entry square, which is safe, so that boundary can never be
// observed; the cases below sit on q + d == 51 (a threat) and q + d == 53 (no
// threat), the nearest pair the rules let a board show.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/move_hint.dart';

const int y = -1;
const int h = 57;

typedef Legal = List<(int, List<int>)>;

String _legalText(Legal legal) =>
    legal.map(((int, List<int>) e) => '${e.$1}: ${e.$2}').join(', ');

String _boardText(int mySeat, Map<int, List<int>> tokens, Legal legal) =>
    'mySeat $mySeat, tokens $tokens, legal {${_legalText(legal)}}';

/// One hint case: the board, the legal list, and the (face, token) the
/// contract's tiers and tie-breaks give by hand.
void hintCase(
  String name, {
  int mySeat = 0,
  required Map<int, List<int>> tokens,
  required Legal legal,
  required int face,
  required int token,
}) {
  test(name, () {
    final MoveHint? got = recommendMove(
      mySeat: mySeat,
      tokens: tokens,
      legal: legal,
    );
    final String board = _boardText(mySeat, tokens, legal);
    expect(
      got,
      isNotNull,
      reason:
          '$name: expected the hint (face $face, token $token), got null. '
          'Reproduce with $board',
    );
    expect(
      (got!.face, got.token),
      (face, token),
      reason:
          '$name: expected (face $face, token $token), got '
          '(face ${got.face}, token ${got.token}). Reproduce with $board',
    );
  });
}

/// A case where the contract's D1 says there is nothing to recommend.
void nullCase(
  String name, {
  int mySeat = 0,
  required Map<int, List<int>> tokens,
  required Legal legal,
}) {
  test(name, () {
    final MoveHint? got = recommendMove(
      mySeat: mySeat,
      tokens: tokens,
      legal: legal,
    );
    expect(
      got,
      isNull,
      reason:
          '$name: expected null (fewer than two different choices), got '
          '(face ${got?.face}, token ${got?.token}). Reproduce with '
          '${_boardText(mySeat, tokens, legal)}',
    );
  });
}

void main() {
  group('D2 tier order, one case per adjacent pair', () {
    // Catches: a capture ranked below reaching home. Token 0 (the D1 first)
    // is the home move, so an implementation that puts home first answers 0.
    //
    // Board: me seat 0 [51, 3, home, home]; seat 1 [48, yard x3]. Face 6.
    // Seat 1's token at q 48 stands on (13 + 48) % 52 = 9. Token 0: 51 + 6 =
    // 57, tier 2 (home). Token 1: 3 + 6 = 9, a main-track square, not safe,
    // with exactly one other-seat token on it: tier 1 (capture). Tier 1 wins.
    hintCase(
      'tier 1 over 2: a capture beats reaching home',
      tokens: {
        0: [51, 3, h, h],
        1: [48, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
    );

    // Catches: an escape ranked above reaching home. The escape is token 0.
    //
    // Board: me [16, 52, yard, yard]; seat 1 [1, yard x3]. Face 5. Seat 1's
    // token stands on 13 + 1 = 14. Token 0 stands on 16: d = 16 - 14 = 2, in
    // 1..6, q + d = 3 <= 51, 16 is not safe, so it is threatened now. It
    // moves to 21, a safe square: not threatened after, no capture (safe):
    // tier 3. Token 1: 52 + 5 = 57, tier 2. Tier 2 wins.
    hintCase(
      'tier 2 over 3: reaching home beats an escape',
      tokens: {
        0: [16, 52, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 1,
    );

    // Catches: an entry ranked above an escape. Token 0 (the D1 first) is
    // the entry.
    //
    // Board: me [yard, 15, home, home]; seat 1 [1, yard x3]. Face 6. Seat 1's
    // token stands on 14. Token 0: yard, enters on square 0 (safe, no
    // capture): tier 4. Token 1 stands on 15: d = 15 - 14 = 1, threatened
    // now; 15 + 6 = 21 is safe, so not threatened after: tier 3. Tier 3 wins.
    hintCase(
      'tier 3 over 4: an escape beats an entry',
      tokens: {
        0: [y, 15, h, h],
        1: [1, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
    );

    // Catches: a safe advance ranked above an entry. Token 0 (the D1 first)
    // is the safe advance.
    //
    // Board: me [10, yard, home, home]; seat 1 all in the yard. Face 6. No
    // other-seat token is on the track, so nothing is a capture and nothing
    // is threatened. Token 0: 10 + 6 = 16, not threatened after: tier 5.
    // Token 1: yard, enters: tier 4. Tier 4 wins.
    hintCase(
      'tier 4 over 5: an entry beats a safe advance',
      tokens: {
        0: [10, y, h, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
    );

    // Catches: tier 5 and tier 6 merged into one pool tie-broken by progress
    // alone. Token 0 has the greater progress and the lower index and loses.
    //
    // Board: me [30, 5, yard, yard]; seat 1 [16, yard x3]. Face 3. Seat 1's
    // token stands on 13 + 16 = 29. Token 0 stands on 30: d = 1, q + d = 17,
    // threatened now; 30 + 3 = 33: d = 4, still threatened after, no capture
    // (nothing on 33), not home, so not an escape: tier 6. Token 1: 5 + 3 =
    // 8, a safe square, not threatened after: tier 5. Tier 5 wins.
    hintCase(
      'tier 5 over 6: a safe advance beats a threatened advance',
      tokens: {
        0: [30, 5, y, y],
        1: [16, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 1,
    );
  });

  group('D2 tier 1 tie-breaks', () {
    // Catches: the mover's safety, or the D1 order, ranked above the loss
    // inflicted. Token 1 captures the greater token and is itself
    // threatened after; token 0 captures a small token and is safe.
    //
    // Board: me [10, 2, yard, yard]; seat 1 [45, 1, 40, yard]. Face 4. Seat
    // 1's tokens stand on (13 + 45) % 52 = 6, 14 and (13 + 40) % 52 = 1.
    // Token 0: 10 + 4 = 14, not safe, exactly one token (seat 1, q 1):
    // capture of progress 1. Token 1: 2 + 4 = 6, not safe, exactly one token
    // (seat 1, q 45): capture of progress 45. Both tier 1; 45 > 1, so token 1
    // wins. (After the capture token 1 stands on 6 with the q 40 token on 1:
    // d = 5, q + d = 45, threatened; token 0 on 14 is not. The contract ranks
    // the captured progress first, so this does not matter.)
    hintCase(
      'capture tie: the greater captured progress wins',
      tokens: {
        0: [10, 2, y, y],
        1: [45, 1, 40, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );

    // Catches: the second tie-break ignored, so the D1 first (token 0) wins.
    //
    // Board (4 seats): me [30, 43, yard, yard]; seat 1 [20, ...]; seat 2 [20,
    // ...]; seat 3 [44, ...]. Face 3. Squares: seat 1 q 20 -> 33, seat 2 q 20
    // -> (26 + 20) = 46, seat 3 q 44 -> (39 + 44) % 52 = 31. Token 0: 30 + 3 =
    // 33, one token (seat 1), captured progress 20. Token 1: 43 + 3 = 46, one
    // token (seat 2), captured progress 20. Equal. After the capture token 0
    // stands on 33 with seat 3's token on 31: d = 2, q + d = 46 <= 51,
    // threatened. Token 1 on 46: seat 1's token on 33 is 13 behind, seat 3's
    // 15 behind, so not threatened. The unthreatened mover wins: token 1.
    hintCase(
      'capture tie: equal captured progress, the safe mover wins',
      tokens: {
        0: [30, 43, y, y],
        1: [20, y, y, y],
        2: [20, y, y, y],
        3: [44, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 1,
    );

    // Catches: the last candidate winning a full tie, or a sort that is not
    // stable.
    //
    // Same squares as above without seat 3's token, so no mover is
    // threatened after either capture. Captured progress is equal (20) and
    // both movers are safe: D1 order, lowest token index in the one face:
    // token 0.
    hintCase(
      'capture tie: a full tie falls to the lowest token index',
      tokens: {
        0: [30, 43, y, y],
        1: [20, y, y, y],
        2: [20, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 0,
    );

    // Catches: ties broken by token index across faces instead of by wire
    // order. Candidates in D1 order: (4, token 1), (3, token 0).
    //
    // Board: me [30, 42, yard, yard]; seat 1 [20, ...]; seat 2 [20, ...].
    // Seat 1's token is on 33, seat 2's on 46. (3, token 0): 30 + 3 = 33,
    // captures progress 20. (4, token 1): 42 + 4 = 46, captures progress 20.
    // Neither mover is threatened after (the remaining other-seat token is
    // 13 or more squares behind or ahead). Full tie: the earliest in D1
    // order, and D1 walks the faces in wire order first: face 4, token 1.
    hintCase(
      'capture tie: wire order of the faces beats the lower token index',
      tokens: {
        0: [30, 42, y, y],
        1: [20, y, y, y],
        2: [20, y, y, y],
      },
      legal: [
        (4, [1]),
        (3, [0]),
      ],
      face: 4,
      token: 1,
    );

    // Same board with the wire order flipped: now (3, token 0) is first.
    hintCase(
      'capture tie: flipping the wire order flips the answer',
      tokens: {
        0: [30, 42, y, y],
        1: [20, y, y, y],
        2: [20, y, y, y],
      },
      legal: [
        (3, [0]),
        (4, [1]),
      ],
      face: 3,
      token: 0,
    );
  });

  group('D2 capture rules', () {
    // Catches: a capture on a safe square. A single other-seat token on
    // square 8 is not a capture (RULES.md 1.3), so token 0 falls to tier 5
    // and the greater-progress tie-break picks token 1.
    //
    // Board: me [3, 20, yard, yard]; seat 1 [47, yard x3]. Face 5. Seat 1's
    // token stands on (13 + 47) % 52 = 8. Token 0: 3 + 5 = 8, safe: no
    // capture; it stands on a safe square, so not threatened after: tier 5.
    // Token 1: 20 + 5 = 25, the other token is 17 behind: not threatened:
    // tier 5. Tier 5 tie: greatest current progress, 20 > 3: token 1.
    hintCase(
      'no capture on safe square 8',
      tokens: {
        0: [3, 20, y, y],
        1: [47, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 1,
    );

    // Catches: the same on the other safe square the contract names, 21.
    //
    // Board: me [16, 30, yard, yard]; seat 1 [8, yard x3]. Face 5. Seat 1's
    // token stands on 13 + 8 = 21. Token 0: 16 + 5 = 21, safe: no capture,
    // not threatened after: tier 5. Token 1: 30 + 5 = 35, the other token
    // is behind by 14: tier 5. Tie: greatest progress, token 1.
    hintCase(
      'no capture on safe square 21',
      tokens: {
        0: [16, 30, y, y],
        1: [8, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 1,
    );

    // Catches: a capture counted when two tokens of different seats share
    // the square (a shelter, RULES.md 28).
    //
    // Board (4 seats): me [10, 22, yard, yard]; seat 1 [1, ...]; seat 2 [40,
    // ...]; seat 3 all yard. Face 4. Seat 1's token stands on 14, seat 2's
    // on (26 + 40) % 52 = 14. Token 0: 10 + 4 = 14, two other-seat tokens
    // there: no capture. Nothing stands 1..6 behind square 14 (squares 8 to
    // 13 are empty), so token 0 is not threatened after: tier 5. Token 1:
    // 22 + 4 = 26, safe: tier 5. Tie: greatest progress, 22 > 10: token 1.
    hintCase(
      'no capture on a square with two tokens of different seats',
      tokens: {
        0: [10, 22, y, y],
        1: [1, y, y, y],
        2: [40, y, y, y],
        3: [y, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );

    // Catches: a block of one seat counted as a single capturable token.
    //
    // Board: me [10, 22, yard, yard]; seat 1 [1, 1, yard, yard]. Face 4. Two
    // seat 1 tokens on 14. Token 0: 10 + 4 = 14: two tokens, no capture,
    // tier 5. Token 1: 22 + 4 = 26, safe, tier 5. Tie: token 1 (22 > 10).
    hintCase(
      'no capture on a block of one opponent',
      tokens: {
        0: [10, 22, y, y],
        1: [1, 1, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );

    // Catches: a capture credited to a move into the home column because its
    // progress aliases a main-track square.
    //
    // Board: me [50, 20, yard, yard]; seat 1 [41, 3, yard, yard]. Face 4.
    // Seat 1's tokens stand on (13 + 41) % 52 = 2 and 16. Token 0: 50 + 4 =
    // 54 is a home-column progress; (0 * 13 + 54) % 52 = 2 would alias the
    // square the q 41 token stands on, but dest 54 is not 0..51, so no
    // capture; it is never threatened: tier 5. Token 1 stands on 20: d = 20 -
    // 16 = 4, q + d = 7, threatened now; 20 + 4 = 24: d = 8, not threatened
    // after: tier 3. Tier 3 beats tier 5: token 1.
    hintCase(
      'no capture on a home-column destination that aliases a track square',
      tokens: {
        0: [50, 20, y, y],
        1: [41, 3, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );
  });

  group('D2 threat rules', () {
    // Catches: no shelter for a pair. Token 0 is threatened now and lands on
    // the square token 1 already holds: not threatened after (RULES.md 21,
    // 28a). That makes it an escape, tier 3; without the shelter it would be
    // tier 6 and token 2 would win.
    //
    // Board (3 seats): me [19, 23, 30, yard]; seat 1 [4, yard x3]; seat 2 [51,
    // 51, yard, yard]. Face 4, legal {4: [0, 2]}: token 1 is held up by seat
    // 2's block on square (26 + 51) % 52 = 25, two tokens, which sits on its
    // road 24..27. Seat 1's token stands on 13 + 4 = 17. Token 0 stands on
    // 19: d = 2, q + d = 6, threatened now. 19 + 4 = 23: not safe, nothing
    // there to capture, but my token 1 already stands there, so it is
    // sheltered: not threatened after. Escape, tier 3. Token 2: 30 + 4 = 34,
    // safe, and 13 squares from the seat 1 token: tier 5. Seat 2's tokens
    // are at q 51, so q + d > 51 for every d: no threat from them. Tier 3
    // wins: token 0.
    hintCase(
      'shelter: landing on my own token is not threatened after',
      tokens: {
        0: [19, 23, 30, y],
        1: [4, y, y, y],
        2: [51, 51, y, y],
      },
      legal: [
        (4, [0, 2]),
      ],
      face: 4,
      token: 0,
    );

    // The control for the case above: token 1 is elsewhere (p 40), so token
    // 0's landing on 23 is unsheltered. Seat 1's token on 17 is 6 behind 23
    // (d = 6, q + d = 10): threatened after, tier 6. Token 2 is tier 5 and
    // wins.
    hintCase(
      'shelter control: with no companion on the square token 0 is exposed',
      tokens: {
        0: [19, 40, 30, y],
        1: [4, y, y, y],
        2: [51, 51, y, y],
      },
      legal: [
        (4, [0, 2]),
      ],
      face: 4,
      token: 2,
    );

    // Catches: q + d < 51 instead of <= 51, or a missing bound. The other
    // token has q 50: it stands on (13 + 50) % 52 = 11 and turns into its
    // home column after two more squares. My token on 14 is d = 3 ahead; 50 + 3
    // = 53 > 51, so it is no threat.
    //
    // Board: me [14, 30, yard, yard]; seat 1 [50, yard x3]. Face 4. Token
    // 0: 14 + 4 = 18. It was not threatened and is not after (d = 7): tier 5.
    // Token 1: 30 + 4 = 34, safe: tier 5. Tie: greatest progress: token 1.
    // An implementation that counts the q 50 token as a threat sees token 0
    // as an escape (tier 3) and answers token 0.
    hintCase(
      'q + d edge: an opponent about to enter its home column is no threat',
      tokens: {
        0: [14, 30, y, y],
        1: [50, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );

    // The same geometry, d = 3, with the opponent at progress 40: it stands
    // on (13 + 40) % 52 = 1 and my token on 4. q + d = 43 <= 51: threatened.
    //
    // Board: me [4, 30, yard, yard]; seat 1 [40, yard x3]. Face 4. Token 0:
    // 4 + 4 = 8, safe: not threatened after: escape, tier 3. Token 1: 30 + 4
    // = 34, safe: tier 5. Tier 3 wins: token 0.
    hintCase(
      'q + d edge: the same geometry at progress 40 is a threat',
      tokens: {
        0: [4, 30, y, y],
        1: [40, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 0,
    );

    // The last square that still counts: q 48 stands on (13 + 48) % 52 = 9,
    // my token on 12 is d = 3 ahead, q + d = 51 <= 51: a threat.
    //
    // Board: me [12, 30, yard, yard]; seat 1 [48, yard x3]. Face 4. Token 0:
    // 12 + 4 = 16: d = 7, not threatened after: escape, tier 3. Token 1: 30 +
    // 4 = 34: tier 5. Tier 3 wins: token 0. Catches an off-by-one on the
    // inclusive bound.
    hintCase(
      'q + d edge: q + d == 51 is still a threat',
      tokens: {
        0: [12, 30, y, y],
        1: [48, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 0,
    );

    // Catches: the distance taken without wrapping across 51 -> 0, which
    // reads a negative number and sees no threat.
    //
    // Board: me [1, 30, yard, yard]; seat 1 [37, yard x3]. Face 4. Seat 1's
    // token stands on (13 + 37) % 52 = 50. My token 0 stands on square 1: d =
    // (1 - 50) mod 52 = 3, q + d = 40 <= 51: threatened. 1 + 4 = 5: d = (5 -
    // 50) mod 52 = 7, not threatened after: escape, tier 3. Token 1: 30 + 4 =
    // 34, safe: tier 5. Tier 3 wins: token 0.
    hintCase(
      'wrap: an opponent on square 50 threatens my token on square 1',
      tokens: {
        0: [1, 30, y, y],
        1: [37, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 0,
    );

    // Catches: a yard token read as standing on the track (progress -1 as
    // square 12, or as its entry square 13), which would make my token 0 an
    // escape.
    //
    // Board: me [15, 30, yard, yard]; seat 1 all in the yard. Face 5. No
    // other-seat token is on the track, so nobody is threatened. Token 0: 15
    // + 5 = 20, tier 5. Token 1: 30 + 5 = 35, tier 5. Tie: greatest progress:
    // token 1.
    hintCase(
      'yard tokens are no threat',
      tokens: {
        0: [15, 30, y, y],
        1: [y, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 1,
    );

    // Catches: a token in the home column treated as standing on the track
    // square its progress aliases. Progress 53 aliases square (0 * 13 + 53)
    // % 52 = 1.
    //
    // Board: me [53, 55, yard, yard]; seat 1 [37, yard x3] on square 50.
    // Face 1. A home-column token is never threatened. Token 0: 53 + 1 = 54,
    // tier 5. Token 1: 55 + 1 = 56, tier 5. Tie: greatest progress: token 1.
    // An implementation that sees token 0 (alias square 1, d = 3) as
    // threatened and the move to 54 as safe makes it an escape and answers
    // token 0.
    hintCase(
      'home column: a token at 53 is never threatened (escape not offered)',
      tokens: {
        0: [53, 55, y, y],
        1: [37, y, y, y],
      },
      legal: [
        (1, [0, 1]),
      ],
      face: 1,
      token: 1,
    );

    // The same alias, caught from the other side: if both ends of the move
    // are read as track squares, token 0 is threatened after as well (54
    // aliases square 2, d = 4) and drops to tier 6.
    //
    // Board: me [53, 30, yard, yard]; seat 1 [37, yard x3] on square 50.
    // Face 1. Token 0: 53 + 1 = 54, never threatened: tier 5. Token 1: 30 +
    // 1 = 31: the other token is 33 behind: tier 5. Tie: greatest progress,
    // 53 > 30: token 0.
    hintCase(
      'home column: a move to 54 is not threatened after',
      tokens: {
        0: [53, 30, y, y],
        1: [37, y, y, y],
      },
      legal: [
        (1, [0, 1]),
      ],
      face: 1,
      token: 0,
    );

    // Catches: a move into home 57 from the home column ranked below an
    // escape.
    //
    // Board: me [20, 53, yard, yard]; seat 1 [3, yard x3] on square 16. Face
    // 4. Token 0 stands on 20: d = 4, q + d = 7, threatened; 20 + 4 = 24: d
    // = 8, not threatened after: tier 3. Token 1: 53 + 4 = 57: tier 2. Tier
    // 2 wins: token 1.
    hintCase(
      'home column: a move from 53 to 57 is tier 2',
      tokens: {
        0: [20, 53, y, y],
        1: [3, y, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
    );
  });

  group('D2 tier 3 and tier 6 tie-breaks', () {
    // Catches: ties in the escape tier going to the lowest index or the
    // lowest progress.
    //
    // Board: me [16, 18, yard, yard]; seat 1 [1, yard x3] on square 14.
    // Face 5. Token 0 on 16: d = 2, threatened; 16 + 5 = 21 is safe:
    // escape. Token 1 on 18: d = 4, threatened; 18 + 5 = 23: d = 9, not
    // threatened after, nothing there to capture: escape. Both tier 3; the
    // greater current progress, 18, wins: token 1.
    hintCase(
      'escape tie: the greater current progress wins (greater at token 1)',
      tokens: {
        0: [16, 18, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 1,
    );

    // The same board with the two tokens swapped: now token 0 is on 18.
    hintCase(
      'escape tie: the greater current progress wins (greater at token 0)',
      tokens: {
        0: [18, 16, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 0,
    );

    // Catches: tier 6 broken by the lowest index.
    //
    // Board: me [24, 25, yard, yard]; seat 1 [10, yard x3] on square 23.
    // Face 3. Token 0 on 24: d = 1, threatened; 24 + 3 = 27 (not safe, not
    // my own token's square): d = 4, q + d = 14, threatened after. Token 1
    // on 25: d = 2; 25 + 3 = 28 (not safe): d = 5, threatened after. No
    // capture (nobody on 27 or 28), no home, no escape, no entry: both tier
    // 6. The greater progress, 25, wins: token 1.
    hintCase(
      'tier 6: every move ends threatened, the greater progress wins (token 1)',
      tokens: {
        0: [24, 25, y, y],
        1: [10, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 1,
    );

    // The same board swapped: token 0 is on 25 (28 after), token 1 on 24 (27
    // after), and token 0 wins.
    hintCase(
      'tier 6: every move ends threatened, the greater progress wins (token 0)',
      tokens: {
        0: [25, 24, y, y],
        1: [10, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 0,
    );
  });

  group('D1 roll queue', () {
    // Catches: a hint that names a token only, or ignores the second face.
    //
    // Board: me [16, 30, yard, yard]; seat 1 [1, yard x3] on square 14.
    // legal = {6: [0, 1, 2, 3], 3: [0, 1]}. Candidates and tiers:
    //   (6, t0) 16 + 6 = 22: token 0 on 16 is threatened now (d = 2) and not
    //           after (d = 8): tier 3.
    //   (6, t1) 30 + 6 = 36: tier 5.   (6, t2), (6, t3): entries, tier 4.
    //   (3, t0) 16 + 3 = 19: d = 5, threatened after: tier 6.
    //   (3, t1) 30 + 3 = 33: tier 5.
    // Tier 3 holds exactly one candidate: face 6, token 0.
    final Legal queue = <(int, List<int>)>[
      (6, [0, 1, 2, 3]),
      (3, [0, 1]),
    ];
    hintCase(
      'roll queue: two faces, the hint names face 6 and token 0',
      tokens: {
        0: [16, 30, y, y],
        1: [1, y, y, y],
      },
      legal: queue,
      face: 6,
      token: 0,
    );

    // The one-face reading of the same board: only face 3 is playable.
    // (3, t0) is tier 6, (3, t1) is tier 5: face 3, token 1. The answer
    // differs from the two-face answer in both fields.
    hintCase(
      'roll queue: the one-face reading of the same board answers differently',
      tokens: {
        0: [16, 30, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 1,
    );

    // Catches: the first face in wire order winning by default. Same
    // candidates, the faces listed the other way round: the single tier 3
    // candidate is still (6, t0).
    hintCase(
      'roll queue: the winning face is found whichever way the faces are listed',
      tokens: {
        0: [16, 30, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (3, [0, 1]),
        (6, [0, 1, 2, 3]),
      ],
      face: 6,
      token: 0,
    );
  });

  group('D1 null when there is nothing to choose', () {
    // Catches: a hint offered for a single candidate, which would spend the
    // one use on nothing. One candidate: one choice.
    nullCase(
      'one candidate gives null',
      tokens: {
        0: [16, y, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (4, [0]),
      ],
    );

    // Catches: two yard tokens on a 6 counted as two choices. Both are the
    // same face and the same progress (-1): one choice, however many tokens.
    nullCase(
      'two yard tokens legal on a 6 and nothing else give null',
      tokens: {
        0: [y, y, h, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
    );

    // Catches: two stacked tokens counted as two choices. Tokens 0 and 1 are
    // both on progress 20 and both legal for face 3: one choice.
    nullCase(
      'two tokens stacked on one square, same face, give null',
      tokens: {
        0: [20, 20, y, y],
        1: [1, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
    );

    // Catches: an empty legal list throwing or answering. Zero choices is
    // fewer than two.
    nullCase(
      'an empty legal list gives null',
      tokens: {
        0: [20, 30, y, y],
        1: [1, y, y, y],
      },
      legal: <(int, List<int>)>[],
    );

    // Catches: yard tokens that are the same choice swallowing a real second
    // choice. Candidates: the yard tokens 0 and 1 (one choice, enter) and
    // token 2 on 10 (a second). Two different choices: a hint exists. Tiers:
    // enter is tier 4, 10 + 6 = 16 with no other-seat token on the track is
    // tier 5. Tier 4: the earliest entry in D1 order, token 0.
    hintCase(
      'two yard tokens plus one other token are two choices',
      tokens: {
        0: [y, y, 10, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1, 2]),
      ],
      face: 6,
      token: 0,
    );

    // Catches: stacked tokens with different faces treated as one choice.
    // The same progress under two faces is two choices (D1: the same choice
    // needs the same face). Board: me [20, 20, yard, yard], no other-seat
    // token on the track. (3, t0) 23 and (4, t1) 24 are both tier 5 with
    // current progress 20: D1 order, face 3 first: (3, token 0).
    hintCase(
      'stacked tokens under two different faces are two choices',
      tokens: {
        0: [20, 20, y, y],
        1: [y, y, y, y],
      },
      legal: [
        (3, [0]),
        (4, [1]),
      ],
      face: 3,
      token: 0,
    );

    // Catches: all stacked-tokens collapsed even when a third token exists.
    // Tokens 0 and 1 (progress 20) are one choice, token 2 (progress 40) a
    // second. All three moves are tier 5 (nobody else on the track). Tier 5
    // tie: greatest current progress, 40: token 2.
    hintCase(
      'a stack plus one other token are two choices',
      tokens: {
        0: [20, 20, 40, y],
        1: [y, y, y, y],
      },
      legal: [
        (3, [0, 1, 2]),
      ],
      face: 3,
      token: 2,
    );
  });

  group('D2 determinism and containment', () {
    // Catches: a random or clock-dependent tie-break, a result outside the
    // legal list, and an input mutated on the way through.
    test(
      'the same input twice gives the same answer and nothing is mutated',
      () {
        final Map<int, List<int>> tokens = <int, List<int>>{
          0: <int>[16, 30, y, y],
          1: <int>[1, y, y, y],
        };
        final Legal legal = <(int, List<int>)>[
          (6, <int>[0, 1, 2, 3]),
          (3, <int>[0, 1]),
        ];
        final String before = _boardText(0, tokens, legal);
        final MoveHint? first = recommendMove(
          mySeat: 0,
          tokens: tokens,
          legal: legal,
        );
        final MoveHint? second = recommendMove(
          mySeat: 0,
          tokens: tokens,
          legal: legal,
        );
        expect(first, isNotNull, reason: 'expected a hint for $before');
        expect(second, isNotNull, reason: 'expected a hint for $before');
        expect(
          (second!.face, second.token),
          (first!.face, first.token),
          reason:
              'two calls on one input must agree; got '
              '(${first.face}, ${first.token}) then (${second.face}, '
              '${second.token}). Reproduce with $before',
        );
        expect(
          _boardText(0, tokens, legal),
          before,
          reason: 'recommendMove changed its arguments. Started as $before',
        );
      },
    );

    // Catches: a hint outside the legal list, an invented face or token, a
    // null where two choices exist, and a hint where fewer than two exist.
    // Boards come from a seeded generator; a failure prints the seed.
    test('over 400 seeded boards the answer is determined, inside legal, and '
        'null exactly when D1 says so', () {
      for (int seed = 1; seed <= 400; seed++) {
        final Random rng = Random(seed);
        final int others = 1 + rng.nextInt(3);
        final Map<int, List<int>> tokens = <int, List<int>>{};
        for (int seat = 0; seat <= others; seat++) {
          tokens[seat] = <int>[
            for (int t = 0; t < 4; t++) rng.nextBool() ? y : (rng.nextInt(58)),
          ];
        }
        final int faceCount = 1 + rng.nextInt(3);
        final List<int> faces = <int>[1, 2, 3, 4, 5, 6]..shuffle(rng);
        final Legal legal = <(int, List<int>)>[];
        for (final int face in faces.take(faceCount)) {
          final List<int> movable = <int>[
            for (int t = 0; t < 4; t++)
              if ((tokens[0]![t] == y && face == 6) ||
                  (tokens[0]![t] >= 0 && tokens[0]![t] + face <= 57))
                t,
          ];
          if (movable.isNotEmpty) {
            legal.add((face, movable));
          }
        }
        final Set<String> choices = <String>{
          for (final (int face, List<int> list) in legal)
            for (final int t in list) '$face/${tokens[0]![t]}',
        };
        final String board = 'seed $seed: ${_boardText(0, tokens, legal)}';

        final MoveHint? first = recommendMove(
          mySeat: 0,
          tokens: tokens,
          legal: legal,
        );
        final MoveHint? second = recommendMove(
          mySeat: 0,
          tokens: tokens,
          legal: legal,
        );
        if (choices.length < 2) {
          expect(
            first,
            isNull,
            reason:
                'expected null for ${choices.length} different choice(s), got '
                '(${first?.face}, ${first?.token}). Reproduce with $board',
          );
          continue;
        }
        expect(
          first,
          isNotNull,
          reason:
              'expected a hint for ${choices.length} different choices, got '
              'null. Reproduce with $board',
        );
        expect(
          (second!.face, second.token),
          (first!.face, first.token),
          reason: 'two calls disagreed. Reproduce with $board',
        );
        final bool named = legal.any(
          ((int, List<int>) e) =>
              e.$1 == first.face && e.$2.contains(first.token),
        );
        expect(
          named,
          isTrue,
          reason:
              'the hint (face ${first.face}, token ${first.token}) is not '
              'in legal. Reproduce with $board',
        );
      }
    });
  });
}
