// docs/RULES.md rule 5 and docs/ENGINE_API.md section 7: the dice.
//
// Per the work order: do not brute-force the rejection branch (it is
// reachable roughly once in a billion draws, and searching for it here
// would either never finish or prove nothing). Instead pin the constants
// the spec prints by computing an expected sequence "by hand" from a
// from-scratch reimplementation of section 7 (test/support/splitmix64.dart)
// and comparing it against what the engine actually draws from the same
// starting rngState.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/splitmix64.dart';

/// Draws [count] raw die values from the engine, starting at [rngState],
/// by driving real RollIntention/MoveIntention traffic through the public
/// API. A roll that opens awaitMove is always resolved by moving
/// `legalTokens(state).first`, which never touches rngState (section 7:
/// "nothing else in the engine consumes randomness"), so every value
/// collected here is a genuine, unmodified die draw.
///
/// If the seat driving the draws wins outright, a fresh synthetic
/// await-roll state is spliced in, continuing from the same rngState, so a
/// short game never truncates a long statistical sample.
List<int> _engineRollSequence(int rngState, int count) {
  final draws = <int>[];
  var state = buildAwaitRoll(seats: twoPlayerSeats, rngState: rngState);
  while (draws.length < count) {
    if (isTerminal(state)) {
      state = buildAwaitRoll(seats: twoPlayerSeats, rngState: state.rngState);
      continue;
    }
    if (state.phase == GamePhase.awaitMove) {
      final legal = legalTokens(state);
      final result =
          apply(state, MoveIntention(state.currentSeat, legal.first));
      if (result is! Applied) {
        fail('driver produced a rejected move on its own legal token: $result');
      }
      state = result.state;
      continue;
    }
    final result = apply(state, RollIntention(state.currentSeat));
    if (result is! Applied) {
      fail('driver produced a rejected roll on its own turn: $result');
    }
    for (final event in result.events) {
      if (event is Rolled) {
        draws.add(event.value);
      }
    }
    state = result.state;
  }
  return draws.sublist(0, count);
}

void main() {
  test('rule 5: a roll is always a uniform integer 1 to 6 inclusive', () {
    final draws = _engineRollSequence(123456789, 3000);
    for (final value in draws) {
      expect(value, inInclusiveRange(1, 6));
    }
  });

  test(
    'section 7: the distribution over a few thousand draws is not '
    'obviously broken',
    () {
      const total = 6000;
      final draws = _engineRollSequence(42, total);
      final counts = List<int>.filled(7, 0);
      for (final value in draws) {
        counts[value]++;
      }
      const expectedPerFace = total / 6;
      for (var face = 1; face <= 6; face++) {
        expect(
          counts[face],
          inInclusiveRange(
            (expectedPerFace * 0.8).floor(),
            (expectedPerFace * 1.2).ceil(),
          ),
          reason: 'face $face was drawn ${counts[face]} times in $total draws '
              'from rngState=42, well outside 20% of the expected '
              '${expectedPerFace.round()}: $counts',
        );
      }
    },
  );

  test('section 7: the same starting rngState replays the same sequence', () {
    final first = _engineRollSequence(2026081900, 500);
    final second = _engineRollSequence(2026081900, 500);
    expect(second, equals(first));
  });

  test(
    'section 7: a known starting rngState produces the exact sequence '
    'computed by hand from the SplitMix64 and rejection-sampling formulas '
    'the spec prints',
    () {
      const seed = 9999999999;
      final expected = referenceRollSequence(seed, 500);
      final actual = _engineRollSequence(seed, 500);
      expect(
        actual,
        equals(expected),
        reason: 'the engine\'s draws from rngState=$seed must match a '
            'from-scratch reimplementation of docs/ENGINE_API.md section 7; '
            'a mismatch here means the engine is not using SplitMix64 with '
            'the exact constants and rejection threshold the spec prints',
      );
    },
  );
}
