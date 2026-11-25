// Order C-705t, section 34 item 5: the computer's choice. The ranking is the
// app's hint (order 648, rules D2 to D7): least expected loss over all the
// seat's pieces, then most gain, then first in wire order. Where the hint
// would name nothing (one choice only) the computer plays that one choice.
//
// Each position below is built on a real 2-seat computer room (the human is
// seat 0, the computer seat 2) by putting the engine state in an exact
// position the way the c700 suites do (`forceTurn`), at the moment the
// computer is on turn, and then moving the fake clock until the computer
// acts. The assertion reads the real `moved` frame. The choice function has
// no fixed name here; nothing below calls it.
//
// Geometry used in every hand computation (order 648): progress -1 is the
// yard, 0..51 the main track, 52..56 the home column, 57 home. A token of
// seat s at progress p in 0..51 stands on absolute square (13 * s + p) % 52.
// The computer is seat 2, so its square is (26 + p) % 52; the human is seat
// 0, so its square is p. Safe absolute squares: 0, 8, 13, 21, 26, 34, 39, 47.
// D2: a destination in 0..51 that is not safe and holds exactly one token of
// one other seat captures it. D3: my token is sheltered when it is off the
// track, on a safe square, or paired with another of mine. D4: F(t) is the
// set of faces d in 1..6 with some opponent token at progress q in 0..51,
// (S - square(q)) mod 52 == d and q + d <= 51. D5: with one opponent seat
// hit216 = 216 - (6 - |F|) * 36 (the pad is 6^(3 - 1)); loss = sum over
// unsheltered tokens of hit216 * (progress + 1). D6: gain = steps + (victim progress + 1
// if a capture) + 6 if dest is 57 + 6 if leaving the yard. D7: lowest loss,
// then highest gain, then first in wire order (face in queue order, then
// lowest token index).
//
// The human's tokens are placed so that they threaten exactly what the
// position says; every other token of either seat is in the yard, where it
// threatens nothing (a yard token enters on a safe square) and is not a
// candidate for the face queued.

import 'package:test/test.dart';

import 'c705_computer_seats_test.dart';
import 'support/c700_harness.dart';

const String _file = 'c705_computer_choice_test.dart';

/// One position: the computer's four progress values (seat 2), the human's
/// four (seat 0), the queue, and the move the ranking must give.
class _Position {
  const _Position({
    required this.row,
    required this.why,
    required this.computer,
    required this.human,
    required this.queue,
    required this.token,
    required this.face,
    required this.from,
    required this.to,
    this.captures = false,
  });

  final String row;
  final String why;
  final List<int> computer;
  final List<int> human;
  final List<int> queue;
  final int token;
  final int face;
  final int from;
  final int to;
  final bool captures;
}

const List<_Position> _positions = <_Position>[
  // CH-01 captures when it can. Computer [20, 5, -, -], human [35, -, -, -],
  // face 4. The capture is the SECOND candidate in wire order, so wire order
  // alone would pick the wrong token.
  //   token 0: 20 -> 24, square (26 + 24) % 52 = 50. Human token 35 stands on
  //     square 35; distance to my token 1 (square 31) is (31 - 35) mod 52 =
  //     48, to token 0 after the move (50 - 35) = 15: out of reach. No
  //     unsheltered token is hit, loss 0. gain = 4.
  //   token 1: 5 -> 9, square 35, not safe, exactly one opponent token on it:
  //     captured (progress 35, victim bonus 36). The human has nothing left on
  //     the track, so loss 0. gain = 4 + 36 = 40.
  //   Equal loss 0; gain 40 beats 4: token 1.
  _Position(
    row: 'CH-01 it captures when it can',
    why: 'D2 and D6: the capture of a piece on progress 35 is worth 36 more '
        'than the plain step, losses tie at 0, so token 1 (second in wire '
        'order) wins over token 0',
    computer: <int>[20, 5, -1, -1],
    human: <int>[35, -1, -1, -1],
    queue: <int>[4],
    token: 1,
    face: 4,
    from: 5,
    to: 9,
    captures: true,
  ),
  // CH-02 leaves the yard on a six. Computer [10, -, -, -], human all in the
  // yard, face 6. Candidates: token 0 (10 -> 16) and the yard exit (tokens 1,
  // 2, 3 are one choice: same face, same progress; the first of them is token
  // 1). Loss is 0 for both (the human has no token on the track). gain:
  //   token 0: 6 steps = 6.
  //   token 1: dest 0, 1 step + 6 for leaving the yard = 7.
  //   Gain 7 beats 6: token 1, from -1 to 0, although token 0 is first in
  //   wire order.
  _Position(
    row: 'CH-02 it leaves the yard on a six',
    why: 'D6: leaving the yard is 1 step + 6 = 7, a step of 6 is 6; losses '
        'tie at 0; the exit is token 1, not the wire-first token 0',
    computer: <int>[10, -1, -1, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[6],
    token: 1,
    face: 6,
    from: -1,
    to: 0,
  ),
  // CH-03 it does not walk a piece off a safe square into reach. Computer
  // [8, 30, -, -], human [33, -, -, -], face 3. Token 0 stands on progress 8,
  // square 34 (safe). Token 1 on progress 30, square (26 + 30) % 52 = 4.
  //   token 0: 8 -> 11, square 37, not safe, unpaired: unsheltered. Human
  //     token 33 is 37 - 33 = 4 behind it, 33 + 4 <= 51: F = {4}, |F| = 1.
  //     hit216 = 216 - 5 * 36 = 36.
  //     loss = 36 * (11 + 1) = 432. Token 1 (square 4) is 23 ahead of the
  //     human mod 52: out of reach, adds 0. gain 3.
  //   token 1: 30 -> 33, square 7: (7 - 33) mod 52 = 26, out of reach. Token 0
  //     stays on the safe square 34: sheltered. loss 0. gain 3.
  //   Loss 0 beats 432: token 1, although token 0 is first in wire order.
  _Position(
    row: 'CH-03 it does not leave a safe square into reach',
    why: 'D3 to D5: moving token 0 off the safe square 34 onto square 37, '
        'four in front of the human token, costs 432; token 1 costs 0 at '
        'the same gain',
    computer: <int>[8, 30, -1, -1],
    human: <int>[33, -1, -1, -1],
    queue: <int>[3],
    token: 1,
    face: 3,
    from: 30,
    to: 33,
  ),
  // CH-04a it takes the only move when there is one. Computer [-, -, 15, -],
  // face 2: only token 2 can move (the yard needs a six). Nothing to rank:
  // the hint would name nothing, the computer plays that one choice.
  _Position(
    row: 'CH-04a the only move is played',
    why: 'D1: one legal choice, the hint names nothing, the computer plays '
        'the single legal token (token 2)',
    computer: <int>[-1, -1, 15, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[2],
    token: 2,
    face: 2,
    from: 15,
    to: 17,
  ),
  // CH-04b two tokens on the same progress are one choice (D1: same face and
  // same progress), so the hint names nothing and the first candidate, token
  // 0, is played.
  _Position(
    row: 'CH-04b same face, same progress is one choice: first candidate',
    why: 'D1: tokens 0 and 1 both on progress 15 are one choice; the first '
        'candidate (token 0) is played',
    computer: <int>[15, 15, -1, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[2],
    token: 0,
    face: 2,
    from: 15,
    to: 17,
  ),
  // CH-05a equal moves fall to wire order. Computer [10, 20, -, -], human all
  // in the yard, face 2: loss 0 for both, gain 2 for both: token 0 (first in
  // wire order). A "most advanced piece" rule would give token 1.
  _Position(
    row: 'CH-05a equal moves fall to wire order (rear token first)',
    why: 'D7: loss 0 and gain 2 tie, wire order decides: token 0, not the '
        'more advanced token 1',
    computer: <int>[10, 20, -1, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[2],
    token: 0,
    face: 2,
    from: 10,
    to: 12,
  ),
  // CH-05b the same with the order of progress reversed: token 0 is the more
  // advanced one now. A "least advanced piece" rule would give token 1.
  _Position(
    row: 'CH-05b equal moves fall to wire order (front token first)',
    why: 'D7: loss 0 and gain 2 tie, wire order decides: token 0, not the '
        'less advanced token 1',
    computer: <int>[20, 10, -1, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[2],
    token: 0,
    face: 2,
    from: 20,
    to: 22,
  ),
  // CH-06 the exposed piece is the one that moves (the case the order was
  // written for). Computer [21, 5, -, -], human [29, -, -, -], face 6. Token 0
  // on progress 21, square 47: safe. Token 1 on progress 5, square 31.
  //   token 0: 21 -> 27, square (26 + 27) % 52 = 1: the human token 29 is
  //     (1 - 29) mod 52 = 24 away, out of reach, so token 0 itself is safe
  //     to land. But token 1 stays on square 31, 2 in front of the human
  //     token: F = {2}, hit216 = 216 - 5 * 36 = 36, loss = 36 * (5 + 1) =
  //     216. gain 6.
  //   token 1: 5 -> 11, square 37: (37 - 29) = 8 > 6, out of reach. Token 0
  //     stays on the safe square 47. loss 0. gain 6.
  //   Loss 0 beats 216: token 1 (second in wire order).
  _Position(
    row: 'CH-06 the exposed piece moves out of reach',
    why: 'D5: leaving token 1 two squares in front of the human costs 216, '
        'moving it out of reach costs 0, same gain',
    computer: <int>[21, 5, -1, -1],
    human: <int>[29, -1, -1, -1],
    queue: <int>[6],
    token: 1,
    face: 6,
    from: 5,
    to: 11,
  ),
  // CH-07 faces are ranked too. Computer [20, -, -, -], human all in the yard,
  // queue [2, 5]: candidates (face 2, token 0) and (face 5, token 0), loss 0
  // for both, gain 2 and 5: the face 5 wins although face 2 is first in the
  // queue.
  _Position(
    row: 'CH-07 the best face of the queue is spent',
    why: 'D6/D7: candidates are (face, token) pairs; gain 5 beats gain 2 at '
        'equal loss, so face 5 is spent first although face 2 is queued '
        'first',
    computer: <int>[20, -1, -1, -1],
    human: <int>[-1, -1, -1, -1],
    queue: <int>[2, 5],
    token: 0,
    face: 5,
    from: 20,
    to: 25,
  ),
];

void main() {
  group('section 34 item 5: the choice, five fixed positions and more', () {
    for (final int computerSeed in <int>[3, 4]) {
      for (final _Position p in _positions) {
        final String name = '${p.row} [computerSeed $computerSeed]';
        c705Scenario(
          name,
          (C705Rig r) async {
            final Game705 g = await playComputer(r, players: 2);
            final Driver d = Driver(r, g);
            await d.untilComputerTurn(g.botSeats, p.row);
            final int bot = d.log.last.seat!;
            forceTurn(
              r,
              g.code,
              seat: bot,
              queue: p.queue,
              tokens: <int, List<int>>{bot: p.computer, g.seat: p.human},
            );
            d.auto = false;
            final Frame705 moved = await d.run(
              until: (Frame705 f) => f.t == 'moved' && f.seat == bot,
              row: '${p.row}: the computer should have moved within 1700 ms '
                  'of the position (queue ${p.queue}, computer ${p.computer}, '
                  'human ${p.human})',
              maxIter: 25,
            );
            final String got = fdesc(moved.f);
            final String expected = 'token ${p.token} face ${p.face} from '
                '${p.from} to ${p.to}${p.captures ? ' capturing' : ''}';
            expect(
              <Object?>[
                moved.d['token'],
                moved.d['face'],
                moved.d['from'],
                moved.d['to'],
              ],
              <Object?>[p.token, p.face, p.from, p.to],
              reason: '${p.row}: expected $expected (${p.why}); the server '
                  'played: $got. Position: queue ${p.queue}, computer seat '
                  '$bot ${p.computer}, human seat ${g.seat} ${p.human}.',
            );
            final List<Object?> captured =
                (moved.d['captured'] as List<Object?>?) ?? <Object?>[];
            expect(
              captured.isNotEmpty,
              p.captures,
              reason:
                  '${p.row}: expected ${p.captures ? 'a capture' : 'no capture'}; '
                  'got $got',
            );
            expect(
              moved.d.containsKey('by'),
              isFalse,
              reason: '${p.row}: a computer move carries no by; got $got',
            );
          },
          computerSeed: computerSeed,
          file: _file,
        );
      }
    }
  });
}
