// C-704t: checkFairness on real transcripts. Every transcript below is built
// with packages/fair_dice (DiceChain.build for the chain, drawDie for each
// face), never with scripted faces, so a pass means the check agrees with the
// same code the server rolls with. Each case names its scenario and the
// secret it was built from, so a failure can be rebuilt by hand.
//
// Contract: docs/FAIRNESS.md (hash chain, per-roll draw) and the C-704 order:
// `reason` is one of 'gap', 'chain', 'value', 'no_game_started', 'no_rolls'
// and null when fair; `badK` is the first roll that failed.

import 'package:fair_dice/fair_dice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/fair_check.dart';
import 'package:ludo_client/src/net/frame.dart';

const String _gameId = 'c704-game-0001';
const String _seeds = '0:sam-seed,1:bob-seed';
const int _chainLength = 64;

List<int> _secretOf(int tag) =>
    List<int>.generate(32, (int i) => (i * 7 + tag * 13 + 1) & 0xff);

int _frameCounter = 0;
String _nextId() {
  _frameCounter += 1;
  return 'c704-frame-${_frameCounter.toString().padLeft(6, '0')}';
}

Frame _frame(String type, Map<String, Object?> data) =>
    Frame(type: type, id: _nextId(), data: data);

Frame _gameStarted({String gameId = _gameId, String seeds = _seeds}) =>
    _frame('game_started', <String, Object?>{
      'turn': 0,
      'game_id': gameId,
      'client_seeds': seeds,
      'seq': 2,
    });

Frame _rolled(DiceChain chain, int k, {int? value, String? reveal}) {
  final String real = chain.reveal(k);
  return _frame('rolled', <String, Object?>{
    'seat': k % 2,
    'value': value ?? drawDie(real, _gameId, _seeds, k, 0),
    'legal': const <int>[0, 1, 2, 3],
    'k': k,
    'reveal': reveal ?? real,
    'seq': 2 + k,
  });
}

/// A game_started followed by rolls 1..[rolls], each with a moved frame.
List<Frame> _transcript(DiceChain chain, int rolls) {
  final List<Frame> frames = <Frame>[_gameStarted()];
  for (int k = 1; k <= rolls; k++) {
    frames.add(_rolled(chain, k));
    frames.add(
      _frame('moved', <String, Object?>{'seat': k % 2, 'token': 0, 'seq': 99}),
    );
  }
  frames.add(_frame('game_over', <String, Object?>{'winner': 0}));
  return frames;
}

/// A different face from the honest one, always in 1..6.
int _otherFace(int honest) => (honest % 6) + 1;

void _expectMismatch(
  FairCheck got, {
  required String scenario,
  required String reason,
  required Object? badK,
  required int tag,
}) {
  final String how =
      'scenario "$scenario", secret tag $tag, game $_gameId, '
      'seeds "$_seeds", chain length $_chainLength; got $got';
  expect(
    got.verdict,
    FairVerdict.mismatch,
    reason: 'expected a mismatch, a changed transcript passed: $how',
  );
  expect(got.isFair, isFalse, reason: how);
  expect(got.reason, reason, reason: 'expected reason "$reason": $how');
  expect(got.badK, badK, reason: 'expected badK $badK: $how');
}

void main() {
  const int tag = 3;
  late DiceChain chain;
  late String commit;

  setUp(() {
    chain = DiceChain.build(_secretOf(tag), chainLength: _chainLength);
    commit = chain.commit;
  });

  group('checkFairness on a real transcript', () {
    test('an honest game of 40 rolls is fair, every roll counted', () {
      final FairCheck got = checkFairness(
        chainCommit: commit,
        frames: _transcript(chain, 40),
      );
      final String how =
          'scenario "honest 40 rolls", secret tag $tag; got $got';
      expect(got.verdict, FairVerdict.fair, reason: how);
      expect(got.isFair, isTrue, reason: how);
      expect(got.rolls, 40, reason: 'expected 40 rolls checked: $how');
      expect(got.badK, isNull, reason: how);
      expect(got.reason, isNull, reason: how);
    });

    test('a one-roll game is fair', () {
      final FairCheck got = checkFairness(
        chainCommit: commit,
        frames: _transcript(chain, 1),
      );
      expect(
        got,
        const FairCheck(verdict: FairVerdict.fair, rolls: 1),
        reason: 'scenario "honest 1 roll", secret tag $tag; got $got',
      );
    });

    test('the last roll of the chain is checked like any other', () {
      final FairCheck got = checkFairness(
        chainCommit: commit,
        frames: _transcript(chain, _chainLength),
      );
      expect(
        got,
        const FairCheck(verdict: FairVerdict.fair, rolls: _chainLength),
        reason: 'scenario "honest full chain", secret tag $tag; got $got',
      );
    });

    test('one value changed is a value mismatch at that roll', () {
      for (final int bad in <int>[1, 17, 40]) {
        final List<Frame> frames = <Frame>[_gameStarted()];
        for (int k = 1; k <= 40; k++) {
          final int honest = drawDie(chain.reveal(k), _gameId, _seeds, k, 0);
          frames.add(
            _rolled(chain, k, value: k == bad ? _otherFace(honest) : null),
          );
        }
        _expectMismatch(
          checkFairness(chainCommit: commit, frames: frames),
          scenario: 'value changed at k=$bad of 40',
          reason: 'value',
          badK: bad,
          tag: tag,
        );
      }
    });

    test('a value outside 1..6 is a value mismatch', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(),
        _rolled(chain, 1),
        _rolled(chain, 2, value: 7),
      ];
      _expectMismatch(
        checkFairness(chainCommit: commit, frames: frames),
        scenario: 'value 7 at k=2',
        reason: 'value',
        badK: 2,
        tag: tag,
      );
    });

    test('a value that is not a number is a value mismatch', () {
      final Frame bad = _frame('rolled', <String, Object?>{
        'k': 1,
        'reveal': chain.reveal(1),
        'value': '4',
      });
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[_gameStarted(), bad],
        ),
        scenario: 'value sent as a string at k=1',
        reason: 'value',
        badK: 1,
        tag: tag,
      );
    });

    test('one link changed is a chain mismatch at that roll', () {
      final DiceChain other = DiceChain.build(
        _secretOf(tag + 1),
        chainLength: _chainLength,
      );
      for (final int bad in <int>[1, 2, 9]) {
        final List<Frame> frames = <Frame>[_gameStarted()];
        for (int k = 1; k <= 10; k++) {
          frames.add(
            _rolled(chain, k, reveal: k == bad ? other.reveal(k) : null),
          );
        }
        _expectMismatch(
          checkFairness(chainCommit: commit, frames: frames),
          scenario: 'reveal swapped for another chain at k=$bad of 10',
          reason: 'chain',
          badK: bad,
          tag: tag,
        );
      }
    });

    test('a reveal that is not 64 hex characters is a chain mismatch', () {
      for (final String reveal in <String>[
        '',
        'abc',
        chain.reveal(2).toUpperCase(),
        '${chain.reveal(2)}00',
      ]) {
        final List<Frame> frames = <Frame>[
          _gameStarted(),
          _rolled(chain, 1),
          _rolled(chain, 2, reveal: reveal),
        ];
        _expectMismatch(
          checkFairness(chainCommit: commit, frames: frames),
          scenario: 'malformed reveal "$reveal" at k=2',
          reason: 'chain',
          badK: 2,
          tag: tag,
        );
      }
    });

    test('a reveal that is missing is a chain mismatch', () {
      final Frame bad = _frame('rolled', <String, Object?>{'k': 1, 'value': 3});
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[_gameStarted(), bad],
        ),
        scenario: 'no reveal key at k=1',
        reason: 'chain',
        badK: 1,
        tag: tag,
      );
    });

    test('a missing k (a skipped roll) is a gap at the roll that was due', () {
      final List<Frame> frames = <Frame>[_gameStarted()];
      for (int k = 1; k <= 8; k++) {
        if (k != 4) {
          frames.add(_rolled(chain, k));
        }
      }
      _expectMismatch(
        checkFairness(chainCommit: commit, frames: frames),
        scenario: 'roll k=4 of 8 left out',
        reason: 'gap',
        badK: 4,
        tag: tag,
      );
    });

    test('a roll frame with no k at all is a gap', () {
      final Frame bad = _frame('rolled', <String, Object?>{
        'value': 3,
        'reveal': chain.reveal(1),
      });
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[_gameStarted(), bad],
        ),
        scenario: 'rolled frame without k',
        reason: 'gap',
        badK: 1,
        tag: tag,
      );
    });

    test('a game that starts at k=2 is a gap at k=1', () {
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[_gameStarted(), _rolled(chain, 2), _rolled(chain, 3)],
        ),
        scenario: 'first roll k=1 left out',
        reason: 'gap',
        badK: 1,
        tag: tag,
      );
    });

    test('a replayed roll (the same k twice) is a gap', () {
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[
            _gameStarted(),
            _rolled(chain, 1),
            _rolled(chain, 2),
            _rolled(chain, 2),
            _rolled(chain, 3),
          ],
        ),
        scenario: 'roll k=2 sent twice',
        reason: 'gap',
        badK: anyOf(2, 3),
        tag: tag,
      );
    });

    test('rolls out of order are a gap', () {
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[
            _gameStarted(),
            _rolled(chain, 1),
            _rolled(chain, 3),
            _rolled(chain, 2),
          ],
        ),
        scenario: 'k=3 before k=2',
        reason: 'gap',
        badK: 2,
        tag: tag,
      );
    });

    test('the wrong commit fails at the first roll as a chain mismatch', () {
      final String wrong = DiceChain.build(
        _secretOf(tag + 5),
        chainLength: _chainLength,
      ).commit;
      _expectMismatch(
        checkFairness(chainCommit: wrong, frames: _transcript(chain, 12)),
        scenario: 'commit of another chain',
        reason: 'chain',
        badK: 1,
        tag: tag,
      );
    });

    test('an empty or malformed commit fails as a chain mismatch', () {
      for (final String wrong in <String>['', 'a' * 63, 'g' * 64]) {
        _expectMismatch(
          checkFairness(chainCommit: wrong, frames: _transcript(chain, 3)),
          scenario: 'commit "$wrong"',
          reason: 'chain',
          badK: 1,
          tag: tag,
        );
      }
    });

    test('no game_started is its own mismatch with no roll named', () {
      final List<Frame> frames = <Frame>[
        for (int k = 1; k <= 5; k++) _rolled(chain, k),
      ];
      _expectMismatch(
        checkFairness(chainCommit: commit, frames: frames),
        scenario: 'five rolls, no game_started',
        reason: 'no_game_started',
        badK: null,
        tag: tag,
      );
    });

    test('an empty frame list is no_game_started', () {
      _expectMismatch(
        checkFairness(chainCommit: commit, frames: const <Frame>[]),
        scenario: 'no frames at all',
        reason: 'no_game_started',
        badK: null,
        tag: tag,
      );
    });

    test('a game_started without seeds cannot seed a draw', () {
      final Frame bare = _frame('game_started', <String, Object?>{
        'game_id': _gameId,
      });
      _expectMismatch(
        checkFairness(
          chainCommit: commit,
          frames: <Frame>[bare, _rolled(chain, 1)],
        ),
        scenario: 'game_started with no client_seeds',
        reason: 'no_game_started',
        badK: null,
        tag: tag,
      );
    });

    test('a game with zero rolls is no_rolls, never fair', () {
      final List<Frame> frames = <Frame>[
        _gameStarted(),
        _frame('turn', <String, Object?>{'seat': 0}),
        _frame('game_over', <String, Object?>{'winner': 0}),
      ];
      _expectMismatch(
        checkFairness(chainCommit: commit, frames: frames),
        scenario: 'game_started then game_over, zero rolls',
        reason: 'no_rolls',
        badK: null,
        tag: tag,
      );
    });

    test(
      'wrong game id or seeds change every face, so the first roll fails',
      () {
        final List<Frame> wrongGame = <Frame>[
          _gameStarted(gameId: 'c704-other-game'),
          for (int k = 1; k <= 20; k++) _rolled(chain, k),
        ];
        final FairCheck a = checkFairness(
          chainCommit: commit,
          frames: wrongGame,
        );
        expect(
          a.verdict,
          FairVerdict.mismatch,
          reason:
              'scenario "game_started names a different game id", secret tag '
              '$tag; 20 faces drawn for $_gameId must not all match another '
              'id; got $a',
        );
        expect(a.reason, 'value', reason: 'got $a');
      },
    );

    test(
      'frames of other types are ignored, even when they carry roll keys',
      () {
        final List<Frame> frames = <Frame>[
          _frame('room', <String, Object?>{'chain_commit': 'f' * 64}),
          _gameStarted(),
          _frame('turn', <String, Object?>{'seat': 0, 'k': 77}),
          _rolled(chain, 1),
          _frame('moved', <String, Object?>{
            'k': 99,
            'reveal': 'b' * 64,
            'value': 9,
          }),
          _frame('pong', <String, Object?>{'seq': 1}),
          _rolled(chain, 2),
          _frame('chat', <String, Object?>{'k': 1, 'reveal': 'c' * 64}),
          _frame('some_future_type', <String, Object?>{'k': 5}),
          _rolled(chain, 3),
          _frame('game_over', <String, Object?>{'winner': 1, 'k': 4}),
        ];
        final FairCheck got = checkFairness(
          chainCommit: commit,
          frames: frames,
        );
        expect(
          got,
          const FairCheck(verdict: FairVerdict.fair, rolls: 3),
          reason:
              'scenario "three rolls among room, turn, moved, pong, chat, an '
              'unknown type and game_over frames that carry k or reveal '
              'keys", secret tag $tag; got $got',
        );
      },
    );

    test('a tampered frame of another type does not turn a fair game red', () {
      final List<Frame> frames = _transcript(chain, 6)
        ..add(_frame('moved', <String, Object?>{'value': 1, 'reveal': 'zz'}));
      final FairCheck got = checkFairness(chainCommit: commit, frames: frames);
      expect(
        got.isFair,
        isTrue,
        reason: 'scenario "garbage in a moved frame"; got $got',
      );
    });

    test(
      'the same input gives the same answer twice and does not mutate it',
      () {
        final List<Frame> frames = _transcript(chain, 10);
        final int before = frames.length;
        final FairCheck first = checkFairness(
          chainCommit: commit,
          frames: frames,
        );
        final FairCheck second = checkFairness(
          chainCommit: commit,
          frames: frames,
        );
        expect(
          second,
          first,
          reason: 'scenario "pure function"; $first $second',
        );
        expect(frames.length, before);
      },
    );
  });

  group('FairCheck value equality', () {
    test('equal fields are equal and hash alike', () {
      const FairCheck a = FairCheck(
        verdict: FairVerdict.mismatch,
        rolls: 3,
        badK: 3,
        reason: 'value',
      );
      const FairCheck b = FairCheck(
        verdict: FairVerdict.mismatch,
        rolls: 3,
        badK: 3,
        reason: 'value',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const FairCheck(
            verdict: FairVerdict.mismatch,
            rolls: 3,
            badK: 3,
            reason: 'chain',
          ),
        ),
      );
    });
  });
}
