// Tests for lib/src/game_stats.dart (not yet written; order 232 writes it in
// parallel), against work/ludo/orders/C-232-game-stats.md read in full and
// nothing else. Every definition number in comments below is that
// contract's own numbering.
//
// This file will not compile until lib/src/game_stats.dart exists: that is
// expected and is reported, not worked around.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/net/frame.dart';

int _idCounter = 0;

/// A fresh, valid `id` (docs/PROTOCOL.md section 1: 8 to 64 characters, each
/// in `[A-Za-z0-9_-]`) for every frame this file builds, so no test ever
/// relies on a frame's `id` to mean anything.
String _nextId() {
  _idCounter += 1;
  return 'stats-frame-${_idCounter.toString().padLeft(6, '0')}';
}

Frame _frame(String type, Map<String, Object?> data) {
  return Frame(type: type, id: _nextId(), data: data);
}

Frame _gameStarted(int seq, {String gameId = 'game-1'}) =>
    _frame('game_started', <String, Object?>{
      'seq': seq,
      'turn': 0,
      'game_id': gameId,
      'client_seeds': 'seed-a,seed-b',
    });

Frame _turn(int seq, {required int seat, int deadlineMs = 45000}) => _frame(
  'turn',
  <String, Object?>{'seq': seq, 'seat': seat, 'deadline_ms': deadlineMs},
);

Frame _rolled(
  int seq, {
  required int seat,
  required int value,
  List<int> legal = const <int>[0],
  int k = 1,
}) => _frame('rolled', <String, Object?>{
  'seq': seq,
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': 40000,
  'k': k,
  'reveal': List<String>.filled(64, 'a').join(),
});

Frame _moved(
  int seq, {
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  bool extraRoll = false,
}) => _frame('moved', <String, Object?>{
  'seq': seq,
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
});

Frame _turnPassed(
  int seq, {
  required int seat,
  String reason = 'no_legal_move',
}) => _frame('turn_passed', <String, Object?>{
  'seq': seq,
  'seat': seat,
  'reason': reason,
});

Frame _gameOver(int seq, {required int winner}) =>
    _frame('game_over', <String, Object?>{
      'seq': seq,
      'winner': winner,
      'verify_url': 'https://example.test/verify/game-1',
    });

/// docs/PROTOCOL.md section 6. Only `seq` is read by computeGameStats, but
/// the rest is filled in realistically so this reads like a frame a real
/// server would send, not a seq wearing a costume.
Frame _room(int seq, {required int turnSeat}) =>
    _frame('room', <String, Object?>{
      'seq': seq,
      'code': 'K7M2QP',
      'state': 'PLAYING',
      'host_seat': 0,
      'players': 2,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': List<String>.filled(64, 'b').join(),
      'chain_index': 0,
      'game_id': 'game-1',
      'client_seeds': 'seed-a,seed-b',
      'seats': <Map<String, Object?>>[
        <String, Object?>{
          'seat': 0,
          'name': 'Alice',
          'connected': true,
          'tokens': <int>[3, -1, -1, -1],
          'client_seed': 'seed-a',
          'seed_origin': 'player',
        },
        <String, Object?>{
          'seat': 1,
          'name': 'Bob',
          'connected': true,
          'tokens': <int>[4, -1, -1, -1],
          'client_seed': 'seed-b',
          'seed_origin': 'player',
        },
      ],
      'turn': <String, Object?>{'seat': turnSeat, 'phase': 'await_roll'},
      'winner': null,
    });

/// Carries no `seq` (docs/PROTOCOL.md section 5): used to prove a seq-less
/// frame between two contiguous seq-carrying frames does not break
/// definition 7.
Frame _errorFrame() =>
    _frame('error', <String, Object?>{'code': 'INTERNAL', 'message': 'boom'});

/// Structural equality for the JSON-shaped values that live in a Frame's
/// `data`. Frame does not override `==`, and neither does anything it
/// holds, so comparing a frame list before and after a call needs a
/// field-by-field walk rather than `expect(a, equals(b))` doing the right
/// thing by accident.
bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void main() {
  group(
    'golden transcript: 2-seat game, both seats computed from the same frames',
    () {
      // Hand-counted below. seq runs 100..123 with no gap and no repeat, so
      // complete is true for both seats (completeness does not depend on
      // seat). Every frame in this window carries `seq`
      // (docs/PROTOCOL.md section 5's carrying list has all nine types used
      // here), so every one of them participates in the contiguity check.
      final List<Frame> golden = <Frame>[
        _gameStarted(100), // definition 1: opens the window
        _turn(
          101,
          seat: 0,
        ), // the standalone turn after game_started; no counter
        _rolled(102, seat: 0, value: 3, k: 1), // rolls(seat0): 0 -> 1
        _moved(
          103,
          seat: 0,
          token: 0,
          from: -1,
          to: 3,
        ), // seat0 moves, no capture
        _turn(104, seat: 1), // no counter
        _rolled(
          105,
          seat: 1,
          value: 6,
          k: 2,
        ), // seat1's six must not touch seat0's rolls/sixes
        _moved(
          106,
          seat: 1,
          token: 0,
          from: -1,
          to: 6,
          extraRoll: true,
        ), // seat1 moves, no capture
        _turn(107, seat: 1), // extra roll, same seat; no counter
        _rolled(108, seat: 1, value: 2, k: 3), // rolls(seat1): 1 -> 2
        _moved(
          109,
          seat: 1,
          token: 0,
          from: 6,
          to: 8,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 0},
          ],
        ), // seat1 captures seat0: capturesMade(seat1) 0->1, timesCaptured(seat0) 0->1
        _turn(110, seat: 0), // no counter
        _rolled(
          111,
          seat: 0,
          value: 6,
          k: 4,
        ), // rolls(seat0): 1 -> 2, sixes(seat0): 0 -> 1
        _moved(
          112,
          seat: 0,
          token: 1,
          from: -1,
          to: 0,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          extraRoll: true,
        ), // seat0 captures seat1: capturesMade(seat0) 0->1, timesCaptured(seat1) 0->1
        _turn(113, seat: 0), // extra roll, same seat; no counter
        _rolled(114, seat: 0, value: 4, k: 5), // rolls(seat0): 2 -> 3
        _moved(115, seat: 0, token: 0, from: 3, to: 7), // no capture
        _turn(116, seat: 1), // no counter
        _room(
          117,
          turnSeat: 1,
        ), // mid-game snapshot, contiguous seq; no counter
        _rolled(
          118,
          seat: 1,
          value: 1,
          k: 4,
          legal: const <int>[],
        ), // rolls(seat1): 2 -> 3
        _turnPassed(119, seat: 1), // carries seq; no counter
        _turn(120, seat: 0), // no counter
        _rolled(121, seat: 0, value: 5, k: 6), // rolls(seat0): 3 -> 4
        _moved(122, seat: 0, token: 1, from: 0, to: 5), // no capture
        _gameOver(123, winner: 0), // definition 1: closes the window
      ];

      test('seat 0: rolls 4, sixes 1, capturesMade 1, timesCaptured 1, tokensHome from finalTokens', () {
        final GameStats stats = computeGameStats(
          frames: golden,
          seat: 0,
          finalTokens: <int>[57, 57, 10, 0],
        );
        // rolls: seq 102 (3), 111 (6), 114 (4), 121 (5) -> 4.
        // sixes: of those, only seq 111 -> 1.
        // capturesMade: moved frames with seat 0: seq 103 (0), 112 (1), 115 (0), 122 (0) -> 1.
        // timesCaptured: captured entries with seat 0 across every moved frame: seq 109 has one -> 1.
        // tokensHome: finalTokens has two 57s.
        expect(
          stats,
          const GameStats(
            rolls: 4,
            sixes: 1,
            capturesMade: 1,
            timesCaptured: 1,
            tokensHome: 2,
            complete: true,
          ),
        );
      });

      test('seat 1: rolls 3, sixes 1, capturesMade 1, timesCaptured 1, tokensHome from finalTokens', () {
        final GameStats stats = computeGameStats(
          frames: golden,
          seat: 1,
          finalTokens: <int>[57, 3, 5, 20],
        );
        // rolls: seq 105 (6), 108 (2), 118 (1) -> 3.
        // sixes: of those, only seq 105 -> 1.
        // capturesMade: moved frames with seat 1: seq 106 (0), 109 (1) -> 1.
        // timesCaptured: captured entries with seat 1 across every moved frame: seq 112 has one -> 1.
        // tokensHome: finalTokens has one 57.
        expect(
          stats,
          const GameStats(
            rolls: 3,
            sixes: 1,
            capturesMade: 1,
            timesCaptured: 1,
            tokensHome: 1,
            complete: true,
          ),
        );
      });
    },
  );

  group('definition 1: the game window', () {
    test('only frames after the last game_started and before the next game_over count', () {
      // Game A: deliberately gappy, out-of-order seq (1, 5, 9, 20) that
      // would fail definition 7 on its own -- proof that game A's seq is
      // irrelevant once game B supersedes it. Game A's roll is a six so a
      // mutation that counts the whole list instead of the window shows up
      // as a nonzero sixes(seat0) below.
      final Frame gameAStarted = _gameStarted(1, gameId: 'game-a');
      final Frame gameARolled = _rolled(5, seat: 0, value: 6, k: 1);
      final Frame gameAMoved = _moved(9, seat: 0, token: 0, from: -1, to: 6);
      final Frame gameAOver = _gameOver(20, winner: 0);

      // Game B: the real window, contiguous on its own.
      final Frame gameBStarted = _gameStarted(50, gameId: 'game-b');
      final Frame gameBRolled = _rolled(51, seat: 0, value: 3, k: 1);
      final Frame gameBMoved = _moved(52, seat: 0, token: 0, from: -1, to: 3);
      final Frame gameBOver = _gameOver(53, winner: 0);

      // Trailing noise after game B's own game_over: a six that must not
      // reach sixes(seat0) either.
      final Frame trailingRolled = _rolled(999, seat: 0, value: 6, k: 99);

      final GameStats stats = computeGameStats(
        frames: <Frame>[
          gameAStarted,
          gameARolled,
          gameAMoved,
          gameAOver,
          gameBStarted,
          gameBRolled,
          gameBMoved,
          gameBOver,
          trailingRolled,
        ],
        seat: 0,
        finalTokens: <int>[57, 0, 0, 0],
      );
      // catches: counting the whole list instead of the window.
      expect(
        stats,
        const GameStats(
          rolls: 1,
          sixes: 0,
          capturesMade: 0,
          timesCaptured: 0,
          tokensHome: 1,
          complete: true,
        ),
      );
    });

    test('no game_started at all gives zero counters, complete false, tokensHome still from finalTokens', () {
      final GameStats stats = computeGameStats(
        frames: <Frame>[
          _turn(1, seat: 0),
          _rolled(2, seat: 0, value: 6, k: 1),
          _moved(3, seat: 0, token: 0, from: -1, to: 6),
        ],
        seat: 0,
        finalTokens: <int>[57, 57, 0, 0],
      );
      expect(
        stats,
        const GameStats(
          rolls: 0,
          sixes: 0,
          capturesMade: 0,
          timesCaptured: 0,
          tokensHome: 2,
          complete: false,
        ),
      );
    });
  });

  group('definition 2: rolls', () {
    test(
      'counts only rolled frames whose seat matches the seat under test',
      () {
        final List<Frame> frames = <Frame>[
          _gameStarted(1),
          _turn(2, seat: 0),
          _rolled(3, seat: 0, value: 2, k: 1),
          _moved(4, seat: 0, token: 0, from: -1, to: 2),
          _turn(5, seat: 1),
          _rolled(6, seat: 1, value: 4, k: 1),
          _rolled(7, seat: 1, value: 5, k: 2),
          _moved(8, seat: 1, token: 0, from: -1, to: 5),
          _turn(9, seat: 0),
          _rolled(10, seat: 0, value: 1, k: 2),
          _moved(11, seat: 0, token: 0, from: 2, to: 3),
          _gameOver(12, winner: 0),
        ];
        // catches: counting the opponent's rolls.
        expect(
          computeGameStats(
            frames: frames,
            seat: 0,
            finalTokens: <int>[0, 0, 0, 0],
          ).rolls,
          2,
        );
        expect(
          computeGameStats(
            frames: frames,
            seat: 1,
            finalTokens: <int>[0, 0, 0, 0],
          ).rolls,
          2,
        );
      },
    );
  });

  group('definition 3: sixes', () {
    test('counts only the seat\'s own rolled frames whose value is 6', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(1),
        _turn(2, seat: 0),
        _rolled(3, seat: 0, value: 6, k: 1),
        _moved(4, seat: 0, token: 0, from: -1, to: 6, extraRoll: true),
        _turn(5, seat: 0),
        _rolled(6, seat: 0, value: 3, k: 2),
        _moved(7, seat: 0, token: 0, from: 6, to: 9),
        _turn(8, seat: 1),
        _rolled(9, seat: 1, value: 6, k: 1),
        _moved(10, seat: 1, token: 0, from: -1, to: 6, extraRoll: true),
        _turn(11, seat: 1),
        _rolled(12, seat: 1, value: 6, k: 2),
        _moved(13, seat: 1, token: 0, from: 6, to: 12, extraRoll: true),
        _turn(14, seat: 1),
        _rolled(15, seat: 1, value: 6, k: 3),
        _moved(16, seat: 1, token: 0, from: 12, to: 18),
        _gameOver(17, winner: 1),
      ];
      final GameStats seat0 = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      final GameStats seat1 = computeGameStats(
        frames: frames,
        seat: 1,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(seat0.rolls, 2);
      expect(seat0.sixes, 1);
      // seat1 rolled three sixes out of three rolls: sixes must track value,
      // not simply mirror rolls.
      expect(seat1.rolls, 3);
      expect(seat1.sixes, 3);
    });
  });

  group('definition 4: capturesMade', () {
    test('sums captured.length over the seat\'s own moved frames, including a double capture', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(1),
        _turn(2, seat: 0),
        _rolled(3, seat: 0, value: 4, k: 1),
        _moved(
          4,
          seat: 0,
          token: 0,
          from: -1,
          to: 4,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
            <String, Object?>{'seat': 1, 'token': 1},
          ],
        ), // one moved frame, two captured entries: capturesMade +2, not +1
        _turn(5, seat: 1),
        _rolled(6, seat: 1, value: 2, k: 1),
        _moved(7, seat: 1, token: 2, from: -1, to: 2),
        _turn(8, seat: 0),
        _rolled(9, seat: 0, value: 3, k: 2),
        _moved(
          10,
          seat: 0,
          token: 1,
          from: -1,
          to: 3,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 2},
          ],
        ), // a second, single capture: capturesMade +1 more
        _gameOver(11, winner: 0),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.capturesMade, 3);
    });
  });

  group('definition 5: timesCaptured', () {
    test('counts captured entries naming the seat, over every mover, not just moves the seat made', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(1),
        _turn(2, seat: 1),
        _rolled(3, seat: 1, value: 4, k: 1),
        _moved(
          4,
          seat: 1,
          token: 0,
          from: -1,
          to: 4,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 0},
          ],
        ), // seat1 captures seat0: timesCaptured(seat0) 0 -> 1
        _turn(5, seat: 2),
        _rolled(6, seat: 2, value: 3, k: 1),
        _moved(
          7,
          seat: 2,
          token: 0,
          from: -1,
          to: 3,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 1},
          ],
        ), // seat2 (neither seat0 nor seat1) also captures seat0: timesCaptured(seat0) 1 -> 2
        _gameOver(8, winner: 1),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      // catches: counting captures by mover instead of by the captured seat
      // named inside `captured` ("any mover", definition 5).
      expect(stats.timesCaptured, 2);
      expect(stats.capturesMade, 0); // seat 0 never moved in this window
    });
  });

  group('definition 6: tokensHome', () {
    test(
      'is the count of 57s in finalTokens, independent of what the frames show',
      () {
        // No token in this window ever reaches 57 on the board; finalTokens
        // disagrees with the frames on purpose.
        final List<Frame> frames = <Frame>[
          _gameStarted(1),
          _turn(2, seat: 0),
          _rolled(3, seat: 0, value: 2, k: 1),
          _moved(4, seat: 0, token: 0, from: -1, to: 2),
          _gameOver(5, winner: 0),
        ];
        // catches: counting tokensHome from frames.
        expect(
          computeGameStats(
            frames: frames,
            seat: 0,
            finalTokens: <int>[57, 57, 57, 57],
          ).tokensHome,
          4,
        );
        expect(
          computeGameStats(
            frames: frames,
            seat: 0,
            finalTokens: <int>[0, 0, 0, 0],
          ).tokensHome,
          0,
        );
        expect(
          computeGameStats(
            frames: frames,
            seat: 0,
            finalTokens: <int>[57, 10, 57, 0],
          ).tokensHome,
          2,
        );
      },
    );
  });

  group('definition 7: complete and seq contiguity', () {
    test('a seq gap in the window makes complete false but does not zero the counters', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(10),
        _turn(11, seat: 0),
        _rolled(13, seat: 0, value: 3, k: 1), // skips 12
        _moved(14, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(15, winner: 0),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.complete, false);
      expect(
        stats.rolls,
        1,
      ); // the gap is a completeness problem, not a counting one
    });

    test('a repeated seq in the window makes complete false', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(10),
        _turn(11, seat: 0),
        _rolled(11, seat: 0, value: 3, k: 1), // repeats 11 instead of 12
        _moved(12, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(13, winner: 0),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.complete, false);
    });

    test('a seq-less frame between two contiguous seq-carrying frames does not break completeness', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(50),
        _errorFrame(), // no seq; skipped by the contiguity check
        _rolled(
          51,
          seat: 0,
          value: 3,
          k: 1,
        ), // contiguous with game_started's own 50
        _moved(52, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(53, winner: 0),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.complete, true);
    });

    test('a contiguous mid-game room snapshot keeps completeness', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(1),
        _turn(2, seat: 0),
        _room(3, turnSeat: 0),
        _rolled(4, seat: 0, value: 3, k: 1),
        _moved(5, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(6, winner: 0),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.complete, true);
    });

    test(
      'a room snapshot whose own seq breaks the chain makes complete false',
      () {
        final List<Frame> frames = <Frame>[
          _gameStarted(1),
          _turn(2, seat: 0),
          _room(10, turnSeat: 0), // jumps from 2 to 10
          _rolled(11, seat: 0, value: 3, k: 1),
          _moved(12, seat: 0, token: 0, from: -1, to: 3),
          _gameOver(13, winner: 0),
        ];
        final GameStats stats = computeGameStats(
          frames: frames,
          seat: 0,
          finalTokens: <int>[0, 0, 0, 0],
        );
        // catches: ignoring room seq (treating `room` as exempt from the
        // contiguity check the way `error`/`pong`/`seat_assigned` are).
        expect(stats.complete, false);
      },
    );
  });

  group('definition 8: malformed input never throws', () {
    test('a rolled frame with no seat is not counted toward rolls and makes complete false', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(200),
        _turn(201, seat: 0),
        _frame('rolled', <String, Object?>{
          'seq': 202,
          // no 'seat' key at all.
          'value': 3,
          'legal': <int>[0],
          'deadline_ms': 40000,
          'k': 1,
          'reveal': List<String>.filled(64, 'a').join(),
        }),
        _moved(203, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(204, winner: 0),
      ];
      GameStats? stats;
      expect(() {
        stats = computeGameStats(
          frames: frames,
          seat: 0,
          finalTokens: <int>[0, 0, 0, 0],
        );
      }, returnsNormally);
      expect(stats!.rolls, 0);
      expect(stats!.complete, false);
    });

    test('a rolled frame with a non-int value is not counted toward sixes and makes complete false', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(300),
        _turn(301, seat: 0),
        _frame('rolled', <String, Object?>{
          'seq': 302,
          'seat': 0,
          'value': '6', // a string, not an int: a naive `as int` cast throws
          'legal': <int>[0],
          'deadline_ms': 40000,
          'k': 1,
          'reveal': List<String>.filled(64, 'a').join(),
        }),
        _moved(303, seat: 0, token: 0, from: -1, to: 3),
        _gameOver(304, winner: 0),
      ];
      GameStats? stats;
      expect(() {
        stats = computeGameStats(
          frames: frames,
          seat: 0,
          finalTokens: <int>[0, 0, 0, 0],
        );
      }, returnsNormally);
      // the frame still carries a seat matching ours, so it is a roll;
      // definition 3's field (value) is what is broken, not definition 2's
      // field (seat), so only sixes is affected.
      expect(stats!.rolls, 1);
      expect(stats!.sixes, 0);
      expect(stats!.complete, false);
    });

    test('a moved frame whose captured is not a list is not counted toward capturesMade and makes complete false', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(400),
        _turn(401, seat: 0),
        _rolled(402, seat: 0, value: 4, k: 1),
        _frame('moved', <String, Object?>{
          'seq': 403,
          'seat': 0,
          'token': 0,
          'from': -1,
          'to': 4,
          'captured': 'none', // a string, not a list: `.length` on this is 4, `as List` throws
          'extra_roll': false,
        }),
        _gameOver(404, winner: 0),
      ];
      GameStats? stats;
      expect(() {
        stats = computeGameStats(
          frames: frames,
          seat: 0,
          finalTokens: <int>[0, 0, 0, 0],
        );
      }, returnsNormally);
      expect(stats!.capturesMade, 0);
      expect(stats!.timesCaptured, 0);
      expect(stats!.complete, false);
    });

    test('a captured entry with no int seat is not counted toward timesCaptured, but still counts toward the mover\'s capturesMade length, and makes complete false', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(500),
        _turn(501, seat: 1),
        _rolled(502, seat: 1, value: 5, k: 1),
        _frame('moved', <String, Object?>{
          'seq': 503,
          'seat': 1,
          'token': 0,
          'from': -1,
          'to': 5,
          'captured': <Map<String, Object?>>[
            <String, Object?>{'token': 2}, // no 'seat' key on this entry
          ],
          'extra_roll': false,
        }),
        _gameOver(504, winner: 1),
      ];
      GameStats? statsSeat0;
      GameStats? statsSeat1;
      expect(() {
        statsSeat0 = computeGameStats(
          frames: frames,
          seat: 0,
          finalTokens: <int>[0, 0, 0, 0],
        );
        statsSeat1 = computeGameStats(
          frames: frames,
          seat: 1,
          finalTokens: <int>[0, 0, 0, 0],
        );
      }, returnsNormally);
      // definition 4 is a length, which this malformed entry does not
      // change; definition 5 needs the entry's own int seat, which is
      // absent, so it cannot match seat 0 (or anyone).
      expect(statsSeat1!.capturesMade, 1);
      expect(statsSeat0!.timesCaptured, 0);
      expect(statsSeat0!.complete, false);
      expect(statsSeat1!.complete, false);
    });

    test('a moved frame with no seat still lets its well-formed captured entries count toward timesCaptured (definition 5: any mover)', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(600),
        _turn(601, seat: 1),
        _rolled(602, seat: 1, value: 5, k: 1),
        _frame('moved', <String, Object?>{
          'seq': 603,
          // no 'seat' key for the mover: nobody's capturesMade can credit this move.
          'token': 0,
          'from': -1,
          'to': 5,
          'captured': <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 1},
          ],
          'extra_roll': false,
        }),
        _gameOver(604, winner: 1),
      ];
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      expect(stats.timesCaptured, 1);
      expect(stats.capturesMade, 0);
      expect(stats.complete, false);
    });

    test('seat below the valid range throws ArgumentError', () {
      expect(
        () => computeGameStats(
          frames: const <Frame>[],
          seat: -1,
          finalTokens: <int>[0, 0, 0, 0],
        ),
        throwsArgumentError,
      );
    });

    test('seat above the valid range throws ArgumentError', () {
      expect(
        () => computeGameStats(
          frames: const <Frame>[],
          seat: 4,
          finalTokens: <int>[0, 0, 0, 0],
        ),
        throwsArgumentError,
      );
    });

    test('finalTokens of the wrong length throws ArgumentError', () {
      expect(
        () => computeGameStats(
          frames: const <Frame>[],
          seat: 0,
          finalTokens: <int>[0, 0, 0],
        ),
        throwsArgumentError,
      );
    });

    test('seat 0 and seat 3 are valid boundaries and do not throw', () {
      // No expect(returnsNormally) needed: an unexpected throw here fails
      // the test on its own and prints the exception.
      computeGameStats(
        frames: const <Frame>[],
        seat: 0,
        finalTokens: <int>[0, 0, 0, 0],
      );
      computeGameStats(
        frames: const <Frame>[],
        seat: 3,
        finalTokens: <int>[0, 0, 0, 0],
      );
    });
  });

  group('definition 9: pure and deterministic', () {
    test('calling twice with the same arguments gives an equal result and leaves the input list unchanged', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(1),
        _turn(2, seat: 0),
        _rolled(3, seat: 0, value: 6, k: 1),
        _moved(
          4,
          seat: 0,
          token: 0,
          from: -1,
          to: 6,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          extraRoll: true,
        ),
        _turn(5, seat: 0),
        _rolled(6, seat: 0, value: 2, k: 2),
        _moved(7, seat: 0, token: 0, from: 6, to: 8),
        _room(8, turnSeat: 1),
        _gameOver(9, winner: 0),
      ];
      // A snapshot of every observable field, taken before either call, to
      // compare against after both calls. `data` is copied through
      // jsonEncode/jsonDecode rather than Map.from: Map.from is shallow, so
      // it would share the same nested `captured` lists and `turn`/`rules`
      // maps with the original and miss an in-place mutation of one of
      // those, which is exactly the kind of mutation a careless
      // implementation of capturesMade or timesCaptured could make while
      // walking a `moved` frame's `captured` list.
      final List<Frame> before = <Frame>[
        for (final Frame f in frames)
          Frame(
            type: f.type,
            id: f.id,
            data: jsonDecode(jsonEncode(f.data)) as Map<String, Object?>,
            re: f.re,
            version: f.version,
          ),
      ];

      final GameStats first = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[57, 0, 0, 0],
      );
      final GameStats second = computeGameStats(
        frames: frames,
        seat: 0,
        finalTokens: <int>[57, 0, 0, 0],
      );

      expect(first, second);
      expect(frames.length, before.length);
      for (var i = 0; i < frames.length; i++) {
        expect(frames[i].type, before[i].type, reason: 'frame $i type changed');
        expect(frames[i].id, before[i].id, reason: 'frame $i id changed');
        expect(frames[i].re, before[i].re, reason: 'frame $i re changed');
        expect(
          frames[i].version,
          before[i].version,
          reason: 'frame $i version changed',
        );
        expect(
          _deepEquals(frames[i].data, before[i].data),
          true,
          reason:
              'frame $i data mutated: was ${before[i].data}, now ${frames[i].data}',
        );
      }
    });
  });
}
