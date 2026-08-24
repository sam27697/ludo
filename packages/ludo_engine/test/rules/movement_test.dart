// docs/RULES.md section 4, rules 17-20: movement.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('rule 17: leaving the yard', () {
    test('a token in the yard may leave only on a roll of 6', () {
      for (final roll in const [1, 2, 3, 4, 5]) {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: roll,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        expect(
          legalTokens(state),
          isEmpty,
          reason: 'roll=$roll must not let a yard token move',
        );
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Rejected>(), reason: 'roll=$roll');
        expect((result as Rejected).error, EngineError.illegalMove);
      }
    });

    test(
      'a token leaving the yard on a 6 moves to progress 0 and does not '
      'additionally advance by 6',
      () {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 6,
          sixes: 1,
          tokens: const {
            0: <int>[-1, 57, 57, 57],
          },
        );
        expect(legalTokens(state), const <int>[0]);
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(applied.state.tokens[0][0], 0);
        final moved = applied.events.whereType<Moved>().single;
        expect(moved.from, -1);
        expect(moved.to, 0);
      },
    );
  });

  test(
    'rule 18: a token on the track or in the home column advances by '
    'exactly the rolled value',
    () {
      final onTrack = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 4,
        tokens: const {
          0: <int>[20, 57, 57, 57],
        },
      );
      final trackResult = apply(onTrack, const MoveIntention(0, 0));
      expect(trackResult, isA<Applied>());
      expect((trackResult as Applied).state.tokens[0][0], 24);

      final inHomeColumn = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 2,
        tokens: const {
          0: <int>[53, 57, 57, 57],
        },
      );
      final homeColumnResult = apply(inHomeColumn, const MoveIntention(0, 0));
      expect(homeColumnResult, isA<Applied>());
      expect((homeColumnResult as Applied).state.tokens[0][0], 55);
    },
  );

  group('rule 19: entering home requires an exact roll', () {
    test(
      'a token at progress 55 rolling 4 has no legal move: 55 + 4 = 59 '
      'overshoots 57',
      () {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 4,
          tokens: const {
            0: <int>[55, 57, 57, 57],
          },
        );
        expect(legalTokens(state), isEmpty);
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Rejected>());
        expect((result as Rejected).error, EngineError.illegalMove);
      },
    );

    test(
      'a token at progress 55 rolling exactly 2 reaches home at 57, with '
      'no bounce-back',
      () {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: 2,
          tokens: const {
            0: <int>[55, 0, -1, -1],
          },
        );
        expect(legalTokens(state), contains(0));
        final result = apply(state, const MoveIntention(0, 0));
        expect(result, isA<Applied>());
        final applied = result as Applied;
        expect(
          applied.state.tokens[0][0],
          57,
          reason: 'must land exactly on 57, not bounce back toward 55',
        );
        expect(applied.events.whereType<TokenHome>(), hasLength(1));
      },
    );
  });

  group('rule 20: a token at progress 57 is never movable again', () {
    test('it never appears in legalTokens, for any roll', () {
      for (final roll in const [1, 2, 3, 4, 5, 6]) {
        final state = buildAwaitMove(
          seats: twoPlayerSeats,
          roll: roll,
          sixes: roll == 6 ? 1 : 0,
          tokens: const {
            0: <int>[57, -1, -1, -1],
          },
        );
        expect(
          legalTokens(state),
          isNot(contains(0)),
          reason: 'roll=$roll must not make a home token movable',
        );
      }
    });

    test('selecting it is rejected as illegalMove', () {
      final state = buildAwaitMove(
        seats: twoPlayerSeats,
        roll: 3,
        tokens: const {
          0: <int>[57, -1, -1, -1],
        },
      );
      final result = apply(state, const MoveIntention(0, 0));
      expect(result, isA<Rejected>());
      expect((result as Rejected).error, EngineError.illegalMove);
    });
  });
}
