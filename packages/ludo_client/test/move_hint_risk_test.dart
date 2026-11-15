// Pure-function proof for C-648 D1..D7: recommendMove weighs the pieces a
// move leaves behind. Written from the contract (work/ludo/orders/648-risk-
// aware-move-hint.md), not from any implementation. No widgets, no I/O.
//
// The contract in one place, so every comment below can cite it.
//   Progress follows RULES.md 1.2: -1 yard, 0..51 main track, 52..56 home
//   column, 57 home. Seat s at progress p in 0..51 stands on square
//   (13 * s + p) % 52. Safe squares: 0, 8, 13, 21, 26, 34, 39, 47.
//   D2  dest = 0 from the yard, else p + face. A dest in 0..51 that is not
//       safe and holds exactly one other-seat token captures it (it goes to
//       -1).
//   D3  After the move my token at p is sheltered when p is not in 0..51, or
//       its square is safe, or another of my tokens has the same progress.
//   D4  F_o(t) = faces d in 1..6 such that a token of seat o at q in 0..51
//       has (S - (13 * o + q) % 52) mod 52 == d and q + d <= 51. Yard tokens
//       never threaten. Blocks in between are ignored.
//   D5  hit216(t) = 216 - prod_o (6 - |F_o(t)|) * 6^(3 - number of opponent
//       seats); loss = sum over unsheltered t of hit216(t) * (p(t) + 1).
//   D6  gain = (dest - from) + (victim ? victimProgress + 1 : 0)
//             + (dest == 57 ? 6 : 0) + (from == -1 ? 6 : 0).
//   D7  Lowest loss, then highest gain, then the earlier candidate in D1
//       order (faces in wire order, then lowest token index).
// For one opponent seat the factor is 6^2 = 36, so hit216 = 36 * |F|; for
// two seats it is 6, for three it is 1.
//
// Fillers. A token that is not listed in legal is parked in the yard (-1)
// on a roll that is not a 6 and at home (57) on a roll that is a 6, so a
// filler is never a candidate and never on the track. An opponent token that
// is only there to fill a seat is in the yard, which never threatens (D4).
// Every opponent token that is on the track in a case below is there on
// purpose and the comment says which square it hits.

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

/// One hint case: the board, the legal list, the (face, token) the contract
/// gives by hand, and the hand numbers for the reason text.
void hintCase(
  String name, {
  int mySeat = 0,
  required Map<int, List<int>> tokens,
  required Legal legal,
  required int face,
  required int token,
  required String hand,
}) {
  _referenceAgrees(name, mySeat, tokens, legal, face, token);
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
          'Hand numbers: $hand. Reproduce with $board',
    );
    expect(
      (got!.face, got.token),
      (face, token),
      reason:
          '$name: expected (face $face, token $token), got '
          '(face ${got.face}, token ${got.token}). Hand numbers: $hand. '
          'Reproduce with $board',
    );
  });
}

/// Checks the hand answer of every table case against the proof's own
/// reference arithmetic (below), so a wrong hand computation shows up here
/// and not as a false failure of the code under test.
void _referenceAgrees(
  String name,
  int mySeat,
  Map<int, List<int>> tokens,
  Legal legal,
  int face,
  int token,
) {
  test('$name [reference arithmetic agrees with the hand answer]', () {
    final List<_Row> rows = _referenceRows(mySeat, tokens, legal);
    final _Row want = _referencePick(rows);
    expect(
      (want.face, want.token),
      (face, token),
      reason:
          '$name: the hand answer is (face $face, token $token) but the '
          'reference arithmetic gives (face ${want.face}, token '
          '${want.token}); table ${rows.join('; ')}. Board '
          '${_boardText(mySeat, tokens, legal)}',
    );
  });
}

/// A case where D1 says there is nothing to recommend.
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

// ---------------------------------------------------------------------------
// Reference model for the seeded sweep: D2..D7 written out in integers from
// the contract text above. It is the proof's own arithmetic, kept apart from
// the table cases so a disagreement prints both sides.
// ---------------------------------------------------------------------------

const Set<int> _safe = <int>{0, 8, 13, 21, 26, 34, 39, 47};

int _sq(int seat, int p) => (13 * seat + p) % 52;

class _Row {
  _Row(this.order, this.face, this.token, this.loss, this.gain);
  final int order;
  final int face;
  final int token;
  final int loss;
  final int gain;
  @override
  String toString() =>
      '(face $face, token $token: loss $loss, gain $gain, order $order)';
}

List<_Row> _referenceRows(int mySeat, Map<int, List<int>> tokens, Legal legal) {
  final List<_Row> rows = <_Row>[];
  int order = 0;
  for (final (int face, List<int> list) in legal) {
    for (final int t in list) {
      final int from = tokens[mySeat]![t];
      final int dest = from == -1 ? 0 : from + face;
      final Map<int, List<int>> after = <int, List<int>>{
        for (final MapEntry<int, List<int>> e in tokens.entries)
          e.key: List<int>.of(e.value),
      };
      after[mySeat]![t] = dest;
      int victimProgress = -2;
      if (dest >= 0 && dest <= 51 && !_safe.contains(_sq(mySeat, dest))) {
        final List<(int, int)> on = <(int, int)>[];
        for (final MapEntry<int, List<int>> e in tokens.entries) {
          if (e.key == mySeat) continue;
          for (int i = 0; i < e.value.length; i++) {
            final int q = e.value[i];
            if (q >= 0 && q <= 51 && _sq(e.key, q) == _sq(mySeat, dest)) {
              on.add((e.key, i));
            }
          }
        }
        if (on.length == 1) {
          victimProgress = tokens[on.first.$1]![on.first.$2];
          after[on.first.$1]![on.first.$2] = -1;
        }
      }
      final List<int> opponents = <int>[
        for (final int s in after.keys)
          if (s != mySeat) s,
      ];
      int loss = 0;
      for (final int p in after[mySeat]!) {
        if (p < 0 || p > 51) continue;
        if (_safe.contains(_sq(mySeat, p))) continue;
        if (after[mySeat]!.where((int o) => o == p).length > 1) continue;
        final int square = _sq(mySeat, p);
        int product = 1;
        for (final int o in opponents) {
          final Set<int> faces = <int>{};
          for (final int q in after[o]!) {
            if (q < 0 || q > 51) continue;
            final int d = (square - _sq(o, q)) % 52;
            if (d >= 1 && d <= 6 && q + d <= 51) faces.add(d);
          }
          product *= 6 - faces.length;
        }
        int scale = 1;
        for (int i = 0; i < 3 - opponents.length; i++) {
          scale *= 6;
        }
        loss += (216 - product * scale) * (p + 1);
      }
      final int gain =
          (dest - from) +
          (victimProgress == -2 ? 0 : victimProgress + 1) +
          (dest == 57 ? 6 : 0) +
          (from == -1 ? 6 : 0);
      rows.add(_Row(order, face, t, loss, gain));
      order++;
    }
  }
  return rows;
}

_Row _referencePick(List<_Row> rows) {
  _Row best = rows.first;
  for (final _Row r in rows.skip(1)) {
    if (r.loss < best.loss ||
        (r.loss == best.loss && r.gain > best.gain) ||
        (r.loss == best.loss && r.gain == best.gain && r.order < best.order)) {
      best = r;
    }
  }
  return best;
}

void main() {
  group(
    'a. Sam case: the exposed piece is rescued before the safe one moves',
    () {
      // Shared board shape. Seat 0 (me): token 0 on progress 47 (square 47,
      // safe), token 1 on progress 30 (square 30, open), tokens 2 and 3 at home
      // (fillers, the roll is a 6). Seat 1: one token on the track, the rest in
      // the yard (they never threaten). Legal {6: [0, 1]}.
      //
      // Candidates, both with face 6:
      //   (6, token 0): 47 + 6 = 53 (home column, sheltered). Token 1 stays on
      //     30 with the seat 1 token d behind: F_1 = {d}, hit216 = 216 - 5 * 36
      //     = 36, loss = 36 * 31 = 1116. gain = 6.
      //   (6, token 1): 30 + 6 = 36, open, nobody on it. The seat 1 token is
      //     6 + d > 6 squares behind 36: F_1 = {}, hit216 = 0. Token 0 on 47 is
      //     safe. loss = 0, gain = 6.
      // Loss 0 < 1116: (6, token 1). The old "most advanced piece" tie-break
      // would have named token 0.
      //
      // d = 1: seat 1 token at q 16 stands on (13 + 16) % 52 = 29; 30 - 29 = 1,
      // q + d = 17 <= 51.
      hintCase(
        'Sam case: opponent 1 behind the exposed piece',
        tokens: {
          0: [47, 30, h, h],
          1: [16, y, y, y],
        },
        legal: [
          (6, [0, 1]),
        ],
        face: 6,
        token: 1,
        hand: '(6,0) loss 1116 gain 6; (6,1) loss 0 gain 6',
      );

      // d = 3: q 14 stands on 27; 30 - 27 = 3, q + d = 17. Same numbers as
      // above: (6, token 0) loss 36 * 31 = 1116, (6, token 1) loss 0 (the
      // token on 27 is 9 squares behind 36).
      hintCase(
        'Sam case: opponent 3 behind the exposed piece',
        tokens: {
          0: [47, 30, h, h],
          1: [14, y, y, y],
        },
        legal: [
          (6, [0, 1]),
        ],
        face: 6,
        token: 1,
        hand: '(6,0) loss 1116 gain 6; (6,1) loss 0 gain 6',
      );

      // d = 6: q 11 stands on 24; 30 - 24 = 6, q + d = 17. The far edge of the
      // hit range. (6, token 0) loss 1116; (6, token 1) lands on 36, 12 squares
      // from 24: loss 0.
      hintCase(
        'Sam case: opponent 6 behind the exposed piece',
        tokens: {
          0: [47, 30, h, h],
          1: [11, y, y, y],
        },
        legal: [
          (6, [0, 1]),
        ],
        face: 6,
        token: 1,
        hand: '(6,0) loss 1116 gain 6; (6,1) loss 0 gain 6',
      );

      // The same shape seen from seat 2 against seat 0 (squares are
      // (26 + p) % 52 for me): token 0 on 47 stands on 73 % 52 = 21 (safe);
      // token 1 on 30 stands on 56 % 52 = 4. Seat 0's token at q 1 stands on 1:
      // 4 - 1 = 3, q + d = 4. Opponent seats are the keys other than 2: only
      // seat 0, so the factor is 6^(3-1) = 36. (6, token 0): token 1 stays,
      // hit216 = 216 - 5 * 36 = 36, loss = 36 * 31 = 1116, gain 6. (6, token
      // 1): 30 + 6 = 36 stands on 62 % 52 = 10, 9 squares from square 1: loss
      // 0. Pick (6, token 1).
      hintCase(
        'Sam case as seat 2 against seat 0',
        mySeat: 2,
        tokens: {
          2: [47, 30, h, h],
          0: [1, y, y, y],
        },
        legal: [
          (6, [0, 1]),
        ],
        face: 6,
        token: 1,
        hand: '(6,0) loss 1116 gain 6; (6,1) loss 0 gain 6',
      );

      // Seat 3 against seat 1: token 0 on 47 stands on (39 + 47) % 52 = 34
      // (safe); token 1 on 30 stands on 69 % 52 = 17. Seat 1's token at q 1
      // stands on 14: 17 - 14 = 3, q + d = 4. (6, token 0) loss 1116; (6, token
      // 1) lands on 36 -> square 75 % 52 = 23, 9 squares from 14: loss 0.
      hintCase(
        'Sam case as seat 3 against seat 1 (a map with no seats 0 and 2)',
        mySeat: 3,
        tokens: {
          3: [47, 30, h, h],
          1: [1, y, y, y],
        },
        legal: [
          (6, [0, 1]),
        ],
        face: 6,
        token: 1,
        hand: '(6,0) loss 1116 gain 6; (6,1) loss 0 gain 6',
      );
    },
  );

  group('b. finishing against rescuing', () {
    // Both moves leave the same loss and the finish has the larger gain.
    //
    // Board: me [5, 51, home, home]; seat 1 [42, 43, 48, yard]. Face 6,
    // legal {6: [0, 1]}. Seat 1's tokens stand on (13 + 42) % 52 = 3, 4 and
    // (13 + 48) % 52 = 9. Token 1 on 51 (square 51) is 48 or more squares
    // from every one of them: never hit.
    //   (6, token 0): 5 + 6 = 11 (not safe, nobody on it). Token 0 on 11:
    //     from square 9, d = 2, q + d = 50 <= 51; from 3 and 4 the gaps are
    //     8 and 7. F_1 = {2}, hit216 = 216 - 5 * 36 = 36, loss = 36 * 12 =
    //     432. Token 1 on 51 unhit: 0. loss 432, gain 6.
    //   (6, token 1): 51 + 6 = 57, home, sheltered. Token 0 stays on 5: from
    //     square 4 d = 1, from 3 d = 2 (q + d = 44, 44), square 9 is ahead.
    //     F_1 = {1, 2}, hit216 = 216 - 4 * 36 = 72, loss = 72 * 6 = 432.
    //     gain = 6 + 6 (dest == 57) = 12.
    // Loss ties at 432, gain 12 > 6, so the finish wins (6, token 1). The
    // finishing token has the HIGHER index, so the D1 order cannot decide it.
    hintCase(
      'finish wins when both moves leave the same loss',
      tokens: {
        0: [5, 51, h, h],
        1: [42, 43, 48, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
      hand: '(6,0) loss 432 gain 6; (6,1) loss 432 gain 12',
    );

    // The finish leaves strictly more loss: Sam's exposed piece stays put.
    //
    // Board: me [51, 30, home, home]; seat 1 [14, yard x3] on square 27.
    // Face 6.
    //   (6, token 0): 51 -> 57. Token 1 on 30 stays: d = 3, q + d = 17.
    //     hit216 = 36, loss = 36 * 31 = 1116. gain 12.
    //   (6, token 1): 30 -> 36, 9 squares from 27. Token 0 on 51 is 24
    //     squares from 27: unhit. loss 0, gain 6.
    // 0 < 1116: (6, token 1), even though the finish has twice the gain.
    hintCase(
      'finish loses when it leaves the other piece exposed',
      tokens: {
        0: [51, 30, h, h],
        1: [14, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
      hand: '(6,0) loss 1116 gain 12; (6,1) loss 0 gain 6',
    );

    // Nobody is in range: loss 0 for both, the finish takes the gain.
    //
    // Board: me [51, 20, home, home]; seat 1 all in the yard. Face 6.
    //   (6, token 0): 51 -> 57, loss 0, gain 12. (6, token 1): 20 -> 26,
    //   loss 0, gain 6. Pick (6, token 0).
    hintCase(
      'finish wins when no opponent is on the track',
      tokens: {
        0: [51, 20, h, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 0,
      hand: '(6,0) loss 0 gain 12; (6,1) loss 0 gain 6',
    );
  });

  group('c. a pair stays sheltered', () {
    // Breaking a pair onto a threatened square loses to leaving the pair.
    //
    // Board: me [20, 20, 30, yard]; seat 1 [6, 5, yard, yard]. Face 5, legal
    // {5: [0, 1, 2]} (tokens 0 and 1 are the same choice, D1). Seat 1's
    // tokens stand on 19 (q 6) and 18 (q 5).
    //   (5, token 0): 20 -> 25 (not safe, empty). Token 0 on 25: from 19,
    //     d = 6, q + d = 12; from 18, d = 7. F_1 = {6}, hit216 = 36, loss
    //     36 * 26 = 936. Token 1 is left alone on 20 (no longer a pair):
    //     from 19 d = 1, from 18 d = 2, F_1 = {1, 2}, hit216 = 72, loss 72 *
    //     21 = 1512. Token 2 on 30: 11 or more squares ahead of both, safe
    //     from them. Total loss 2448, gain 5. (5, token 1) is the same board
    //     after the move (same progress, same face): same numbers.
    //   (5, token 2): 30 -> 35. The pair on 20 is sheltered (D3), token 2 on
    //     35 is 16 or more ahead of 19 and 18. loss 0, gain 5.
    // 0 < 2448: (5, token 2). Without D3 the stay would cost 2 * 72 * 21 =
    // 3024 and breaking the pair (2448) would win, so this case catches a
    // missing shelter.
    hintCase(
      'pair: leaving the pair beats breaking it onto a threatened square',
      tokens: {
        0: [20, 20, 30, y],
        1: [6, 5, y, y],
      },
      legal: [
        (5, [0, 1, 2]),
      ],
      face: 5,
      token: 2,
      hand: '(5,0) loss 2448 gain 5; (5,2) loss 0 gain 5',
    );

    // Forming a pair shelters both tokens.
    //
    // Board: me [20, 16, yard, yard]; seat 1 [6, 5, yard, yard] (squares 19
    // and 18). Face 4, legal {4: [0, 1]}.
    //   (4, token 0): 20 -> 24. Token 0 on 24: from 19 d = 5, from 18 d = 6:
    //     F_1 = {5, 6}, hit216 = 72, loss 72 * 25 = 1800. Token 1 on 16: the
    //     opponents are ahead of it: unhit. loss 1800, gain 4.
    //   (4, token 1): 16 -> 20, onto my own token: a pair (D3), sheltered.
    //     loss 0, gain 4.
    // Pick (4, token 1). Without D3 the pair would cost 2 * 72 * 21 = 3024
    // and (4, token 0) at 1800 would win.
    hintCase(
      'pair: moving onto my own token forms a shelter',
      tokens: {
        0: [20, 16, y, y],
        1: [6, 5, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
      hand: '(4,0) loss 1800 gain 4; (4,1) loss 0 gain 4',
    );
  });

  group('d. captures are judged by what they leave behind', () {
    // A capture that leaves another piece exposed loses to a non-capture
    // with lower loss.
    //
    // Board: me [10, 30, yard, yard]; seat 1 [14, 1, yard, yard]. Face 4,
    // legal {4: [0, 1]}. Seat 1's tokens stand on 27 (q 14) and 14 (q 1).
    //   (4, token 0): 10 + 4 = 14, open, exactly one token (seat 1, q 1):
    //     captured, back to the yard. Token 0 on 14: the other seat 1 token
    //     on 27 is ahead: unhit. Token 1 on 30: from 27, d = 3, q + d = 17:
    //     F_1 = {3}, hit216 = 36, loss 36 * 31 = 1116. gain = 4 + (1 + 1) =
    //     6.
    //   (4, token 1): 30 + 4 = 34, safe. Token 0 on 10: the token on 14 is
    //     ahead, the one on 27 is ahead: unhit. loss 0, gain 4.
    // 0 < 1116: (4, token 1), even though the capture has the bigger gain.
    hintCase(
      'capture that leaves a piece exposed loses to a safe non-capture',
      tokens: {
        0: [10, 30, y, y],
        1: [14, 1, y, y],
      },
      legal: [
        (4, [0, 1]),
      ],
      face: 4,
      token: 1,
      hand: '(4,0) loss 1116 gain 6; (4,1) loss 0 gain 4',
    );

    // A capture that removes the only hitter of my exposed piece wins on
    // loss, although another move has the larger gain.
    //
    // Board: me [11, 20, 51, home]; seat 1 [4, yard x3] on square 17. Face
    // 6, legal {6: [0, 1, 2]}.
    //   (6, token 0): 11 + 6 = 17, open, exactly one token (seat 1, q 4):
    //     captured. Token 0 on 17, token 1 on 20, token 2 on 51: no
    //     opponent on the track: loss 0. gain = 6 + (4 + 1) = 11.
    //   (6, token 1): 20 + 6 = 26 (safe). Token 0 on 11 is behind the
    //     opponent: unhit. Token 2 on 51 is 34 squares from 17: unhit.
    //     loss 0, gain 6.
    //   (6, token 2): 51 -> 57. Token 1 on 20 stays: from 17, d = 3, q + d =
    //     7: F_1 = {3}, hit216 = 36, loss 36 * 21 = 756. Token 0 on 11 is
    //     behind: unhit. loss 756, gain 6 + 6 = 12.
    // The finish has the best gain (12) but loss 756; the other two tie at
    // loss 0 and the capture's gain 11 > 6. Pick (6, token 0).
    hintCase(
      'capture that removes the only hitter wins on loss',
      tokens: {
        0: [11, 20, 51, h],
        1: [4, y, y, y],
      },
      legal: [
        (6, [0, 1, 2]),
      ],
      face: 6,
      token: 0,
      hand: '(6,0) loss 0 gain 11; (6,1) loss 0 gain 6; (6,2) loss 756 gain 12',
    );

    // A big capture that lands on a threatened square, with a second piece
    // exposed, loses to a one-step move onto a safe square.
    //
    // Board: me [3, 7, home, home]; seat 1 [48, 45, yard, yard]. Legal {6:
    // [0], 1: [1]}. Seat 1's tokens stand on (13 + 48) % 52 = 9 and
    // (13 + 45) % 52 = 6.
    //   (6, token 0): 3 + 6 = 9, open, exactly one token (q 48): captured.
    //     Token 0 on 9: from 6, d = 3, q + d = 48: F_1 = {3}, hit216 = 36,
    //     loss 36 * 10 = 360. Token 1 on 7: from 6, d = 1: F_1 = {1}, loss
    //     36 * 8 = 288. Loss 648. gain = 6 + (48 + 1) = 55.
    //   (1, token 1): 7 + 1 = 8, safe. Token 0 on 3 is behind both tokens:
    //     unhit. loss 0, gain 1.
    // 0 < 648: (1, token 1).
    hintCase(
      'gain never buys risk: a 55-point capture onto a threatened square',
      tokens: {
        0: [3, 7, h, h],
        1: [48, 45, y, y],
      },
      legal: [
        (6, [0]),
        (1, [1]),
      ],
      face: 1,
      token: 1,
      hand: '(6,0) loss 648 gain 55; (1,1) loss 0 gain 1',
    );
  });

  group('e. gain never buys risk', () {
    // A long move onto a threatened square loses to a short move onto a safe
    // one.
    //
    // Board: me [30, 6, home, home]; seat 1 [20, yard x3] on square 33.
    // Legal {6: [0], 2: [1]}.
    //   (6, token 0): 30 + 6 = 36, open. From 33, d = 3, q + d = 23: F_1 =
    //     {3}, hit216 = 36, loss 36 * 37 = 1332. Token 1 on 6: unhit.
    //     gain 6.
    //   (2, token 1): 6 + 2 = 8, safe. Token 0 on 30 is behind the opponent
    //     on 33: unhit. loss 0, gain 2.
    // 0 < 1332: (2, token 1), the second face in wire order.
    hintCase(
      'gain never buys risk: a 6 onto a threatened square vs a 2 onto safety',
      tokens: {
        0: [30, 6, h, h],
        1: [20, y, y, y],
      },
      legal: [
        (6, [0]),
        (2, [1]),
      ],
      face: 2,
      token: 1,
      hand: '(6,0) loss 1332 gain 6; (2,1) loss 0 gain 2',
    );

    // The yard exit is not a way around a threat either: the exit gains 7,
    // but the piece it leaves exposed costs 1116.
    //
    // Board: me [yard, 30, home, home]; seat 1 [14, yard x3] on square 27.
    // Face 6.
    //   (6, token 0): the exit, dest 0 (safe). Token 1 on 30: from 27, d =
    //     3: hit216 = 36, loss 36 * 31 = 1116. gain = 1 + 6 = 7.
    //   (6, token 1): 30 -> 36, 9 squares from 27: loss 0, gain 6.
    // Pick (6, token 1).
    hintCase(
      'gain never buys risk: the yard exit does not outrank a rescue',
      tokens: {
        0: [y, 30, h, h],
        1: [14, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
      hand: '(6,0) loss 1116 gain 7; (6,1) loss 0 gain 6',
    );
  });

  group('f. the per-seat combination of hit faces (D5)', () {
    // Common board (three seats: me and two opponent seats, so the factor is
    // 6^(3-2) = 6). Face 2, legal {2: [0, 1]}. Token 0 (P) on 19 and token 1
    // (C) on 37 can each reach a safe square with the 2 (21 and 39). Moving
    // one leaves the other where it stands, so the pick is the move that
    // leaves the cheaper piece behind.
    //
    // f1: P is hit by two different seats, one face each.
    //   Seat 1 tokens: q 4 (square 17), q 22 (square 35). Seat 2 token: q 41
    //   (square (26 + 41) % 52 = 15). Rest in the yard.
    //   P on 19: seat 1 from 17, d = 2; seat 2 from 15, d = 4 (q + d = 45).
    //     F_1 = {2}, F_2 = {4}: hit216 = 216 - 5 * 5 * 6 = 66.
    //   C on 37: seat 1 from 35, d = 2: F_1 = {2}, F_2 = {}: hit216 = 216 -
    //     5 * 6 * 6 = 36. Seat 1's token on 17 is 20 behind, seat 2's on 15
    //     is 22 behind.
    //   (2, token 0): P to 21 (safe). C stays: loss 36 * 38 = 1368.
    //   (2, token 1): C to 39 (safe). P stays: loss 66 * 20 = 1320.
    //   Gains 2 and 2. 1320 < 1368: (2, token 1).
    // A reading that merges the two seats' faces into one set of two faces
    // gives P 72: 72 * 20 = 1440 > 1368 and picks (2, token 0).
    hintCase(
      'per seat: two seats with one face each give hit216 66',
      tokens: {
        0: [19, 37, y, y],
        1: [4, 22, y, y],
        2: [41, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 1,
      hand: '(2,0) loss 1368 gain 2; (2,1) loss 1320 gain 2',
    );

    // f2: P is hit by ONE seat with two tokens in range.
    //   Seat 1 tokens: q 4 (square 17), q 2 (square 15), q 22 (square 35).
    //   Seat 2: all yard (it only fills the seat, factor 6).
    //   P on 19: from 17 d = 2, from 15 d = 4: F_1 = {2, 4}. hit216 = 216 -
    //     4 * 6 * 6 = 72.
    //   C on 37: from 35, d = 2: hit216 = 216 - 5 * 6 * 6 = 36 (the tokens
    //     on 17 and 15 are 20 and 22 behind).
    //   (2, token 0): C stays: loss 36 * 38 = 1368.
    //   (2, token 1): P stays: loss 72 * 20 = 1440.
    //   1368 < 1440: (2, token 0). Against f1 the geometry on P is the same
    //   and only the seat split changes: 66 -> 72 flips the pick.
    hintCase(
      'per seat: one seat with two tokens in range gives hit216 72',
      tokens: {
        0: [19, 37, y, y],
        1: [4, 2, 22, y],
        2: [y, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 1368 gain 2; (2,1) loss 1440 gain 2',
    );

    // f3: two seats threaten with the SAME face. Seats do not merge.
    //   Board: me [19, 32, yard, yard]; seat 1 [4, 17, yard, yard] (squares
    //   17 and 30); seat 2 [43, yard x3] (square (26 + 43) % 52 = 17).
    //   P on 19: seat 1 from 17, d = 2; seat 2 from 17, d = 2. F_1 = {2},
    //     F_2 = {2}: hit216 = 216 - 5 * 5 * 6 = 66 (a merged set {2} would
    //     give 36). The seat 1 token on 30 is ahead of P.
    //   C on 32: seat 1 from 30, d = 2: hit216 = 36. The tokens on 17 are 15
    //     behind.
    //   (2, token 0): P to 21 (safe), C stays: loss 36 * 33 = 1188.
    //   (2, token 1): C to 34 (safe), P stays: loss 66 * 20 = 1320.
    //   1188 < 1320: (2, token 0). With a merged set P would cost 36 * 20 =
    //   720 and the answer would be (2, token 1).
    hintCase(
      'per seat: two seats with the same face still give hit216 66',
      tokens: {
        0: [19, 32, y, y],
        1: [4, 17, y, y],
        2: [43, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 1188 gain 2; (2,1) loss 1320 gain 2',
    );

    // f4: three opponent seats, one face each: no padding factor (6^0).
    //   Board: me [19, 51, yard, yard]; seat 1 [4, 36, yard, yard] (squares
    //   17 and 49); seat 2 [43, yard x3] (square 17); seat 3 [30, yard x3]
    //   (square (39 + 30) % 52 = 17).
    //   P on 19: F_1 = {2}, F_2 = {2}, F_3 = {2}: hit216 = 216 - 5 * 5 * 5 =
    //     91.
    //   C on 51: seat 1 from 49, d = 2, q + d = 38: F_1 = {2}: hit216 = 216
    //     - 5 * 6 * 6 = 36. (The tokens on 17 are 34 behind.)
    //   (2, token 0): P to 21 (safe), C stays: loss 36 * 52 = 1872.
    //   (2, token 1): C to 53 (home column), P stays: loss 91 * 20 = 1820.
    //   1820 < 1872: (2, token 1). A sum of the per-seat hits (36 * 3 = 108)
    //   would give 2160 and pick (2, token 0).
    hintCase(
      'per seat: three opponent seats give hit216 91',
      tokens: {
        0: [19, 51, y, y],
        1: [4, 36, y, y],
        2: [43, y, y, y],
        3: [30, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 1,
      hand: '(2,0) loss 1872 gain 2; (2,1) loss 1820 gain 2',
    );

    // Blocks between a hitter and the target are ignored (D4).
    //   Board: me [19, 32, yard, yard]; seat 1 [4, 4, 17, yard] (a block of
    //   two on square 17, and a token on 30); seat 2 [41, yard x3] (square
    //   15).
    //   P on 19: seat 1 block from 17, d = 2: F_1 = {2}. Seat 2 from 15 d =
    //     4, with seat 1's block standing between: still F_2 = {4}. hit216 =
    //     216 - 5 * 5 * 6 = 66.
    //   C on 32: seat 1 from 30, d = 2: hit216 = 36.
    //   (2, token 0): C stays: loss 36 * 33 = 1188.
    //   (2, token 1): P stays: loss 66 * 20 = 1320.
    //   1188 < 1320: (2, token 0). If the block hid seat 2, P would cost 36
    //   * 20 = 720 and the answer would be (2, token 1).
    hintCase(
      'blocks between the hitter and the target are ignored',
      tokens: {
        0: [19, 32, y, y],
        1: [4, 4, 17, y],
        2: [41, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 1188 gain 2; (2,1) loss 1320 gain 2',
    );
  });

  group('g. two-seat game: the 6^(3-1) factor', () {
    // One opponent seat: hit216 = 216 - (6 - |F|) * 36 = 36 * |F|.
    //
    // Board: me [19, 32, yard, yard]; seat 1 [4, 2, 17, yard] (squares 17,
    // 15, 30). Face 2, legal {2: [0, 1]}.
    //   P on 19: from 17 d = 2, from 15 d = 4: F_1 = {2, 4}, hit216 = 72.
    //   C on 32: from 30 d = 2: F_1 = {2}, hit216 = 36. (17 and 15 are 15 and
    //     17 behind.)
    //   (2, token 0): P to 21 (safe), C stays: loss 36 * 33 = 1188.
    //   (2, token 1): C to 34 (safe), P stays: loss 72 * 20 = 1440.
    //   1188 < 1440: (2, token 0). A factor that left the hits nearly equal
    //   (for example 216 - (6 - |F|) * 6, giving 192 and 186) would compare
    //   192 * 20 = 3840 with 186 * 33 = 6138 and answer (2, token 1).
    hintCase(
      'two-seat game: hit216 is 36 per face',
      tokens: {
        0: [19, 32, y, y],
        1: [4, 2, 17, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 1188 gain 2; (2,1) loss 1440 gain 2',
    );
  });

  group('h. D7 order when loss and gain both tie', () {
    // Same face, loss 0 and gain 3 for both: the lower token index, not the
    // more advanced piece.
    //
    // Board: me [10, 20, yard, yard]; seat 1 all in the yard. Face 3.
    //   (3, token 0): 10 -> 13, loss 0, gain 3. (3, token 1): 20 -> 23, loss
    //   0, gain 3. Tie: token 0.
    hintCase(
      'D7: equal loss and gain, the lowest token index wins (no advanced tie-break)',
      tokens: {
        0: [10, 20, y, y],
        1: [y, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
      face: 3,
      token: 0,
      hand: '(3,0) loss 0 gain 3; (3,1) loss 0 gain 3',
    );

    // Two different faces with equal gain: the earlier face in wire order.
    //
    // Board: me [13, 30, yard, yard]; seat 1 [2, yard x3] on square 15.
    // Legal {5: [1], 2: [0]}.
    //   (5, token 1): 30 -> 35, loss 0 (the opponent on 15 is 15 squares
    //     behind 30 and 20 behind 35: out of range; my token 0 on 13 is
    //     safe and behind it anyway). gain 5.
    //   (2, token 0): 13 -> 15, open, exactly one token (seat 1, q 2):
    //     captured. Token 0 on 15 and token 1 on 30: no opponent on the
    //     track, loss 0. gain = 2 + (2 + 1) = 5.
    //   Loss 0 and gain 5 for both: the earlier in D1 order. Faces in wire
    //   order: (5, token 1) first.
    hintCase(
      'D7: equal loss and gain across faces, the first face in wire order',
      tokens: {
        0: [13, 30, y, y],
        1: [2, y, y, y],
      },
      legal: [
        (5, [1]),
        (2, [0]),
      ],
      face: 5,
      token: 1,
      hand: '(5,1) loss 0 gain 5; (2,0) loss 0 gain 5',
    );

    // The same board with the wire order flipped: (2, token 0) is first.
    hintCase(
      'D7: flipping the wire order flips the answer when loss and gain tie',
      tokens: {
        0: [13, 30, y, y],
        1: [2, y, y, y],
      },
      legal: [
        (2, [0]),
        (5, [1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 0 gain 5; (5,1) loss 0 gain 5',
    );
  });

  group('i. the yard exit', () {
    // Exit against a plain advance with equal loss: the exit gains 1 + 6 = 7
    // against 6.
    //
    // Board: me [10, yard, home, home]; seat 1 all in the yard. Face 6.
    //   (6, token 0): 10 -> 16, loss 0, gain 6. (6, token 1): exit to 0
    //   (safe), loss 0, gain 7. Pick (6, token 1), the later index.
    hintCase(
      'exit: wins by one point over a plain 6 at equal loss',
      tokens: {
        0: [10, y, h, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
      hand: '(6,0) loss 0 gain 6; (6,1) loss 0 gain 7',
    );

    // Exit against a finish: the finish gains 6 + 6 = 12 against 7.
    //
    // Board: me [51, yard, home, home]; seat 1 all in the yard. Face 6.
    //   (6, token 0): 51 -> 57, loss 0, gain 12. (6, token 1): exit, loss 0,
    //   gain 7. Pick (6, token 0).
    hintCase(
      'exit: loses to a finish at equal loss',
      tokens: {
        0: [51, y, h, h],
        1: [y, y, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 0,
      hand: '(6,0) loss 0 gain 12; (6,1) loss 0 gain 7',
    );

    // Exit against a small capture: no credit for a capture on the entry
    // square (0 is safe) even when an opponent stands on it.
    //
    // Board: me [yard, 8, home, home]; seat 1 [39, 1, yard, yard]. Seat 1's
    // tokens stand on (13 + 39) % 52 = 0 and 14. Face 6.
    //   (6, token 0): exit to square 0, safe, so the token on it is not
    //     captured. gain = 1 + 6 = 7. Token 1 on 8 is safe. loss 0.
    //   (6, token 1): 8 + 6 = 14, open, exactly one token (q 1): captured.
    //     gain = 6 + (1 + 1) = 8. Token 1 on 14: the token on 0 is 14 behind:
    //     unhit. loss 0.
    //   Pick (6, token 1), 8 > 7. If the exit were credited with capturing
    //   the token on square 0 (progress 39) its gain would be 47.
    hintCase(
      'exit: an opponent on the entry square is not captured',
      tokens: {
        0: [y, 8, h, h],
        1: [39, 1, y, y],
      },
      legal: [
        (6, [0, 1]),
      ],
      face: 6,
      token: 1,
      hand: '(6,0) loss 0 gain 7; (6,1) loss 0 gain 8',
    );
  });

  group('j. hit range edges and unreachable threats', () {
    // q + d == 51 still hits. Seat 1's token at q 49 stands on (13 + 49) %
    // 52 = 10; my token on 12 is d = 2 ahead, q + d = 51.
    //
    // Board: me [30, 12, yard, yard]; seat 1 [49, yard x3]. Face 2.
    //   (2, token 0): 30 -> 32, loss 0 for it; token 1 stays on 12: F_1 =
    //     {2}, hit216 = 36, loss 36 * 13 = 468. gain 2.
    //   (2, token 1): 12 -> 14, 4 squares ahead: F_1 = {}; loss 0. gain 2.
    // 0 < 468: (2, token 1). A bound of q + d < 51 would make both loss 0
    // and answer token 0.
    hintCase(
      'edge: q + d == 51 is a hit',
      tokens: {
        0: [30, 12, y, y],
        1: [49, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 1,
      hand: '(2,0) loss 468 gain 2; (2,1) loss 0 gain 2',
    );

    // q + d == 53 does not hit. Seat 1's token at q 50 stands on 63 % 52 =
    // 11; my token on 14 is d = 3 ahead, q + d = 53 > 51: the token turns
    // into its home column first.
    //
    // Board: me [14, 30, yard, yard]; seat 1 [50, yard x3]. Face 2.
    //   (2, token 0): 14 -> 16, d = 5, still q + d > 51: loss 0, gain 2.
    //   (2, token 1): 30 -> 32: loss 0, gain 2.
    // Tie on loss and gain: the earlier candidate, token 0. A bound that
    // counted the q 50 token would price the token on 14 and answer token 1.
    hintCase(
      'edge: q + d == 53 is not a hit',
      tokens: {
        0: [14, 30, y, y],
        1: [50, y, y, y],
      },
      legal: [
        (2, [0, 1]),
      ],
      face: 2,
      token: 0,
      hand: '(2,0) loss 0 gain 2; (2,1) loss 0 gain 2',
    );

    // Yard tokens never threaten: read as progress -1 a seat 1 token would
    // stand on square 12 and hit my token on 15 (d = 3).
    //
    // Board: me [30, 15, yard, yard]; seat 1 all in the yard. Face 5.
    //   (5, token 0): loss 0, gain 5. (5, token 1): loss 0, gain 5. Tie:
    //   token 0.
    hintCase(
      'yard tokens are no threat: the lowest index wins the full tie',
      tokens: {
        0: [30, 15, y, y],
        1: [y, y, y, y],
      },
      legal: [
        (5, [0, 1]),
      ],
      face: 5,
      token: 0,
      hand: '(5,0) loss 0 gain 5; (5,1) loss 0 gain 5',
    );
  });

  group('k. D1 is unchanged', () {
    // One candidate, however exposed: null.
    nullCase(
      'one candidate with an exposed piece gives null',
      tokens: {
        0: [30, 20, y, y],
        1: [14, y, y, y],
      },
      legal: [
        (4, [0]),
      ],
    );

    // Two stacked tokens, same face, with a seat 1 token behind them: the
    // same choice, null.
    nullCase(
      'a threatened stack under one face gives null',
      tokens: {
        0: [20, 20, y, y],
        1: [4, y, y, y],
      },
      legal: [
        (3, [0, 1]),
      ],
    );
  });

  group('l. seeded sweep against the contract arithmetic', () {
    // Boards come from a seeded generator; the pick is compared with the
    // reference model above (D2..D7 in integers). A failure prints the seed,
    // the board, both picks and the reference table, so it replays with
    // `Random(seed)`.
    test('1500 seeded boards agree with D2..D7', () {
      for (int seed = 1; seed <= 1500; seed++) {
        final Random rng = Random(seed);
        final int mySeat = rng.nextInt(4);
        final List<int> others = <int>[
          for (int s = 0; s < 4; s++)
            if (s != mySeat) s,
        ]..shuffle(rng);
        final int opponentCount = 1 + rng.nextInt(3);
        final Map<int, List<int>> tokens = <int, List<int>>{};
        final List<int> seats = <int>[mySeat, ...others.take(opponentCount)];
        for (final int s in seats) {
          tokens[s] = <int>[
            for (int t = 0; t < 4; t++)
              switch (rng.nextInt(10)) {
                0 || 1 || 2 => y,
                3 => 52 + rng.nextInt(6),
                _ => rng.nextInt(52),
              },
          ];
        }
        final int faceCount = 1 + rng.nextInt(3);
        final List<int> faces = <int>[1, 2, 3, 4, 5, 6]..shuffle(rng);
        final Legal legal = <(int, List<int>)>[];
        for (final int face in faces.take(faceCount)) {
          final List<int> movable = <int>[
            for (int t = 0; t < 4; t++)
              if ((tokens[mySeat]![t] == y && face == 6) ||
                  (tokens[mySeat]![t] >= 0 && tokens[mySeat]![t] + face <= 57))
                t,
          ];
          if (movable.isNotEmpty) legal.add((face, movable));
        }
        final Set<String> choices = <String>{
          for (final (int face, List<int> list) in legal)
            for (final int t in list) '$face/${tokens[mySeat]![t]}',
        };
        final String board = 'seed $seed: ${_boardText(mySeat, tokens, legal)}';
        final MoveHint? got = recommendMove(
          mySeat: mySeat,
          tokens: tokens,
          legal: legal,
        );
        if (choices.length < 2) {
          expect(
            got,
            isNull,
            reason:
                'expected null for ${choices.length} different choice(s), '
                'got (face ${got?.face}, token ${got?.token}). '
                'Reproduce with $board',
          );
          continue;
        }
        final List<_Row> rows = _referenceRows(mySeat, tokens, legal);
        final _Row want = _referencePick(rows);
        expect(
          got,
          isNotNull,
          reason: 'expected ${want.face}/${want.token}, got null. $board',
        );
        expect(
          (got!.face, got.token),
          (want.face, want.token),
          reason:
              'expected (face ${want.face}, token ${want.token}) by D7, got '
              '(face ${got.face}, token ${got.token}). Reference table: '
              '${rows.join('; ')}. Reproduce with $board',
        );
      }
    });
  });
}
