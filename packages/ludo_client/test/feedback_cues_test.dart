// Conformance tests for lib/src/feedback.dart's cuesForFrame, written from
// work/ludo/orders/C-225-feedback.md's cue table (the doctrine's contract,
// section "Deriving cues from the wire") and from docs/PROTOCOL.md section 5
// for the wire fields each frame type carries, against no implementation of
// feedback.dart the author of this file has read. feedback.dart does not
// exist on the branch this file was written on.
//
// Every case asserts the exact cue list, in order, with equals([...]),
// never contains(...): a row of the table that emits the right cues in the
// wrong order, or one extra cue alongside the right ones, is a defect this
// file exists to catch, and contains(...) would let it through.
//
// Frame objects are built with lib/src/net/frame.dart's public const
// constructor only; frame.dart is read, never edited.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/frame.dart';

/// Any well-shaped id works: cuesForFrame reads only type and data.
const String _id = 'AAAAAAAA';

Frame _frame(String type, Map<String, Object?> data) =>
    Frame(type: type, id: _id, data: data);

/// A seat distinct from [seat], in 0..3, used wherever the table needs a
/// "someone else" seat.
int _otherSeat(int seat) => seat == 0 ? 1 : 0;

void main() {
  // --- the table itself, for mySeat 0 and mySeat 2 --------------------------
  for (final int mySeat in <int>[0, 2]) {
    final int other = _otherSeat(mySeat);

    group('C-225 table, mySeat $mySeat', () {
      test('turn: d.seat == mySeat gives [yourTurn]', () {
        final frame = _frame('turn', <String, Object?>{
          'seat': mySeat,
          'deadline_ms': 45000,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(<FeedbackCue>[FeedbackCue.yourTurn]),
          reason:
              'a turn frame naming mySeat ($mySeat) must give exactly '
              '[yourTurn]; frame.data=${frame.data}',
        );
      });

      test('rolled: d.seat == mySeat, legal non-empty gives [canMove]', () {
        final frame = _frame('rolled', <String, Object?>{
          'seat': mySeat,
          'value': 4,
          'legal': <int>[0, 2],
          'deadline_ms': 1000,
          'k': 3,
          'reveal': 'a' * 64,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(<FeedbackCue>[FeedbackCue.canMove]),
          reason:
              'a rolled frame naming mySeat ($mySeat) with a non-empty '
              'legal must give exactly [canMove]; frame.data=${frame.data}',
        );
      });

      test('rolled: d.seat == mySeat, legal empty gives [noMove]', () {
        final frame = _frame('rolled', <String, Object?>{
          'seat': mySeat,
          'value': 6,
          'legal': <int>[],
          'deadline_ms': 1000,
          'k': 4,
          'reveal': 'b' * 64,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(<FeedbackCue>[FeedbackCue.noMove]),
          reason:
              'a rolled frame naming mySeat ($mySeat) with an empty legal '
              'must give exactly [noMove]; frame.data=${frame.data}',
        );
      });

      test('moved: d.seat == mySeat, no capture, not home gives one step per '
          'square travelled', () {
        // from 3 to 9: 6 squares.
        final frame = _frame('moved', <String, Object?>{
          'seat': mySeat,
          'token': 1,
          'from': 3,
          'to': 9,
          'captured': <Object?>[],
          'extra_roll': false,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(List<FeedbackCue>.filled(6, FeedbackCue.step)),
          reason:
              'a moved frame for mySeat ($mySeat) travelling from 3 to 9 '
              '(6 squares), with no capture and not landing on 57, must '
              'give exactly six step cues; frame.data=${frame.data}',
        );
      });

      test('moved: d.seat != mySeat, some captured entry has seat == mySeat, '
          'gives [capturedMe]', () {
        final frame = _frame('moved', <String, Object?>{
          'seat': other,
          'token': 0,
          'from': 5,
          'to': 10,
          'captured': <Object?>[
            <String, Object?>{'seat': mySeat, 'token': 2},
          ],
          'extra_roll': false,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(<FeedbackCue>[FeedbackCue.capturedMe]),
          reason:
              'a moved frame by seat $other capturing a token of mySeat '
              '($mySeat) must give exactly [capturedMe]; '
              'frame.data=${frame.data}',
        );
      });

      test('game_over: d.winner == mySeat gives [win]', () {
        final frame = _frame('game_over', <String, Object?>{
          'winner': mySeat,
          'verify_url': 'https://ludo.provefair.app/v/abc123',
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(<FeedbackCue>[FeedbackCue.win]),
          reason:
              'a game_over frame naming mySeat ($mySeat) as winner must '
              'give exactly [win]; frame.data=${frame.data}',
        );
      });

      test(
        'game_over: d.winner != mySeat, mySeat != null, gives [gameOver]',
        () {
          final frame = _frame('game_over', <String, Object?>{
            'winner': other,
            'verify_url': 'https://ludo.provefair.app/v/abc123',
          });
          expect(
            cuesForFrame(frame, mySeat: mySeat),
            equals(<FeedbackCue>[FeedbackCue.gameOver]),
            reason:
                'a game_over frame naming seat $other (not mySeat, '
                '$mySeat) as winner must give exactly [gameOver]; '
                'frame.data=${frame.data}',
          );
        },
      );

      test('a frame type the table does not mention gives [] (the catch-all '
          'row)', () {
        final frame = _frame('room', <String, Object?>{
          'code': 'K7M2QP',
          'seat': mySeat,
        });
        expect(
          cuesForFrame(frame, mySeat: mySeat),
          equals(const <FeedbackCue>[]),
          reason:
              'a "room" frame is not one of the table rows and must '
              'give []; frame.data=${frame.data}',
        );
      });
    });
  }

  // --- moved: step-count boundary cases, docs/RULES.md progress values -----
  group('moved: step count', () {
    test('from -1 to 0 (leaving the yard) gives exactly one step, never zero '
        'and never the raw difference of 1 - (-1) = 2', () {
      final frame = _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': -1,
        'to': 0,
        'captured': <Object?>[],
        'extra_roll': false,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(<FeedbackCue>[FeedbackCue.step]),
        reason:
            'leaving the yard (from -1 to 0) must give exactly one step '
            'cue, per C-225\'s "1 when from == -1" rule, not to - from '
            '(which would be 1 here by coincidence, but the rule is '
            'explicit that -1 is special-cased); frame.data=${frame.data}',
      );
    });

    test('from 10 to 16 gives exactly six steps', () {
      final frame = _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 2,
        'from': 10,
        'to': 16,
        'captured': <Object?>[],
        'extra_roll': false,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(List<FeedbackCue>.filled(6, FeedbackCue.step)),
        reason:
            'from 10 to 16 is 6 squares and must give exactly six step '
            'cues; frame.data=${frame.data}',
      );
    });

    test('a capture by me that also lands home gives steps, then '
        'capturedOther, then home, in that order', () {
      // from 50 to 57: 7 squares, home square, and a capture on the way.
      final frame = _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 3,
        'from': 50,
        'to': 57,
        'captured': <Object?>[
          <String, Object?>{'seat': 1, 'token': 0},
        ],
        'extra_roll': false,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(<FeedbackCue>[
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.capturedOther,
          FeedbackCue.home,
        ]),
        reason:
            'from 50 to 57 (7 squares) with a non-empty captured and '
            'to == 57 must give seven steps, then capturedOther, then '
            'home, in that exact order; frame.data=${frame.data}',
      );
    });
  });

  // --- routine events from another seat produce nothing ---------------------
  group('another seat\'s routine events produce nothing', () {
    test('another seat\'s moved with no capture of mine gives []', () {
      final frame = _frame('moved', <String, Object?>{
        'seat': 1,
        'token': 0,
        'from': 4,
        'to': 8,
        'captured': <Object?>[],
        'extra_roll': false,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(const <FeedbackCue>[]),
        reason:
            'a moved frame by seat 1, with mySeat 0 and nothing of mine '
            'captured, must give []; frame.data=${frame.data}',
      );
    });

    test('another seat\'s rolled gives []', () {
      final frame = _frame('rolled', <String, Object?>{
        'seat': 1,
        'value': 5,
        'legal': <int>[0],
        'deadline_ms': 1000,
        'k': 2,
        'reveal': 'c' * 64,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(const <FeedbackCue>[]),
        reason:
            'a rolled frame naming seat 1 while mySeat is 0 must give []; '
            'frame.data=${frame.data}',
      );
    });

    test('another seat\'s turn gives []', () {
      final frame = _frame('turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(const <FeedbackCue>[]),
        reason:
            'a turn frame naming seat 1 while mySeat is 0 must give []; '
            'frame.data=${frame.data}',
      );
    });
  });

  // --- multiple tokens of mine captured in one move --------------------------
  group('another seat captures two of my tokens in one move', () {
    test('gives exactly one capturedMe, not two', () {
      final frame = _frame('moved', <String, Object?>{
        'seat': 1,
        'token': 3,
        'from': 20,
        'to': 26,
        'captured': <Object?>[
          <String, Object?>{'seat': 0, 'token': 0},
          <String, Object?>{'seat': 0, 'token': 1},
        ],
        'extra_roll': false,
      });
      expect(
        cuesForFrame(frame, mySeat: 0),
        equals(<FeedbackCue>[FeedbackCue.capturedMe]),
        reason:
            'two of mySeat\'s (0) tokens captured by seat 1 in one move '
            'must still give exactly one capturedMe, however many of '
            'mine were hit; frame.data=${frame.data}',
      );
    });
  });

  // --- mySeat == null: every frame type gives [] -----------------------------
  group('mySeat == null gives [] for every frame type', () {
    final cases = <String, Frame>{
      'turn': _frame('turn', <String, Object?>{
        'seat': 0,
        'deadline_ms': 45000,
      }),
      'rolled (canMove-shaped)': _frame('rolled', <String, Object?>{
        'seat': 0,
        'value': 4,
        'legal': <int>[0],
        'deadline_ms': 1000,
        'k': 1,
        'reveal': 'a' * 64,
      }),
      'rolled (noMove-shaped)': _frame('rolled', <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': 1000,
        'k': 1,
        'reveal': 'a' * 64,
      }),
      'moved (plain)': _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 0,
        'to': 5,
        'captured': <Object?>[],
        'extra_roll': false,
      }),
      'moved (captures a seat-0 token)': _frame('moved', <String, Object?>{
        'seat': 1,
        'token': 0,
        'from': 5,
        'to': 10,
        'captured': <Object?>[
          <String, Object?>{'seat': 0, 'token': 1},
        ],
        'extra_roll': false,
      }),
      'game_over (winner 0)': _frame('game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://ludo.provefair.app/v/abc123',
      }),
      'game_over (winner 1)': _frame('game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'https://ludo.provefair.app/v/abc123',
      }),
    };

    for (final entry in cases.entries) {
      test('${entry.key} gives [] when mySeat is null', () {
        expect(
          cuesForFrame(entry.value, mySeat: null),
          equals(const <FeedbackCue>[]),
          reason:
              'mySeat == null must give [] regardless of frame type or '
              'shape; case "${entry.key}", frame.data=${entry.value.data}',
        );
      });
    }
  });

  // --- malformed frames: [] and never a thrown exception ---------------------
  group('malformed frames give [] and do not throw', () {
    void expectEmptyAndNoThrow(String label, Frame frame, int? mySeat) {
      test('$label gives [] and does not throw', () {
        List<FeedbackCue>? cues;
        expect(
          () => cues = cuesForFrame(frame, mySeat: mySeat),
          returnsNormally,
          reason:
              'cuesForFrame must never throw on a malformed frame ($label); '
              'frame.type=${frame.type}, frame.data=${frame.data}',
        );
        expect(
          cues,
          equals(const <FeedbackCue>[]),
          reason:
              'a malformed frame ($label) must give [], got $cues; '
              'frame.type=${frame.type}, frame.data=${frame.data}',
        );
      });
    }

    expectEmptyAndNoThrow(
      'turn with seat missing entirely',
      _frame('turn', <String, Object?>{'deadline_ms': 45000}),
      0,
    );

    expectEmptyAndNoThrow(
      'rolled with legal not a list (a String)',
      _frame('rolled', <String, Object?>{
        'seat': 0,
        'value': 3,
        'legal': 'not-a-list',
        'deadline_ms': 500,
        'k': 1,
        'reveal': 'a' * 64,
      }),
      0,
    );

    expectEmptyAndNoThrow(
      'moved with to as a String',
      _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 5,
        'to': 'nine',
        'captured': <Object?>[],
        'extra_roll': false,
      }),
      0,
    );

    expectEmptyAndNoThrow(
      'an unknown frame type',
      _frame('confetti_burst', <String, Object?>{'seat': 0}),
      0,
    );

    expectEmptyAndNoThrow(
      'turn_passed (the noMove already came with the rolled that caused '
      'it)',
      _frame('turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      }),
      0,
    );

    // Bonus malformed cases, past the five the order names by name, still
    // squarely inside the table's own catch-all row ("a field missing or
    // of the wrong type" gives []).
    expectEmptyAndNoThrow(
      'rolled with seat as a String, not an int',
      _frame('rolled', <String, Object?>{
        'seat': '0',
        'value': 3,
        'legal': <int>[0],
        'deadline_ms': 500,
        'k': 1,
        'reveal': 'a' * 64,
      }),
      0,
    );

    expectEmptyAndNoThrow(
      'game_over with winner missing entirely',
      _frame('game_over', <String, Object?>{
        'verify_url': 'https://ludo.provefair.app/v/abc123',
      }),
      0,
    );

    expectEmptyAndNoThrow(
      'moved with captured not a list (a String)',
      _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 0,
        'to': 5,
        'captured': 'oops',
        'extra_roll': false,
      }),
      0,
    );

    expectEmptyAndNoThrow(
      'moved with from as a String',
      _frame('moved', <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 'zero',
        'to': 5,
        'captured': <Object?>[],
        'extra_roll': false,
      }),
      0,
    );
  });

  // --- every enum value's id is the wire string C-225 names -----------------
  group('FeedbackCue.id matches the wire string for every value', () {
    const expectedIds = <FeedbackCue, String>{
      FeedbackCue.yourTurn: 'your_turn',
      FeedbackCue.canMove: 'can_move',
      FeedbackCue.noMove: 'no_move',
      FeedbackCue.step: 'step',
      FeedbackCue.capturedOther: 'captured_other',
      FeedbackCue.capturedMe: 'captured_me',
      FeedbackCue.home: 'home',
      FeedbackCue.win: 'win',
      FeedbackCue.gameOver: 'game_over',
      FeedbackCue.invalidTap: 'invalid_tap',
    };

    test('there are exactly ten values, matching C-225\'s enum', () {
      expect(
        FeedbackCue.values,
        hasLength(10),
        reason:
            'C-225 defines exactly ten FeedbackCue values; got '
            '${FeedbackCue.values.length}: ${FeedbackCue.values}',
      );
    });

    for (final entry in expectedIds.entries) {
      test('${entry.key}.id == "${entry.value}"', () {
        expect(
          entry.key.id,
          entry.value,
          reason:
              'FeedbackCue.${entry.key}.id must equal the wire string '
              '"${entry.value}" C-225 names for it; got "${entry.key.id}"',
        );
      });
    }

    test('every FeedbackCue value is covered by the map above', () {
      expect(
        expectedIds.keys.toSet(),
        equals(FeedbackCue.values.toSet()),
        reason:
            'expectedIds must cover every FeedbackCue.values entry, or '
            'this test silently stops proving anything about a new cue; '
            'missing from expectedIds: '
            '${FeedbackCue.values.toSet().difference(expectedIds.keys.toSet())}',
      );
    });
  });
}
