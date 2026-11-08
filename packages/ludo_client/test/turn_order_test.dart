// Pure proofs for C-590 D1: `nextSeatInPlay(seatsInPlay, current)` is the one
// definition of "who plays after the current seat". Written from the
// contract alone (work/ludo/orders/590-turn-order-you-are-next.md, D1): the
// function works on a sorted, de-duplicated copy of the list, answers null
// when that copy has fewer than 2 entries or does not hold `current`, and
// otherwise answers the entry after `current`, wrapping to the first.
//
// `lib/src/turn_order.dart` does not exist on the 590t branch, so this file
// does not compile there; it is green only on the integration of 590 and
// 590t. Every case is a fixed list, there is no seed: a failure line carries
// the input, the current seat, what was expected and what came back, which
// is the whole reproduction (call the function with exactly those two
// arguments).

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/turn_order.dart';

/// Asserts one call and says how to reproduce it when it fails.
void _expectNext(
  String item,
  List<int> seatsInPlay,
  int current,
  int? expected,
) {
  final List<int> before = List<int>.of(seatsInPlay);
  final int? got = nextSeatInPlay(seatsInPlay, current);
  expect(
    got,
    expected,
    reason:
        'C-590 D1 $item: nextSeatInPlay($before, $current) must be '
        '$expected, got $got. Reproduce: call the function with exactly '
        'those two arguments, no other state is involved.',
  );
}

/// The expected answer worked out the slow way, from the rule in the contract
/// ("ascending seat index, wrapping to the lowest"), independent of the
/// function's own sort.
int? _bruteForce(List<int> input, int current) {
  final Set<int> distinct = input.toSet();
  if (distinct.length < 2 || !distinct.contains(current)) {
    return null;
  }
  int? smallestAbove;
  int lowest = distinct.first;
  for (final int seat in distinct) {
    if (seat < lowest) {
      lowest = seat;
    }
    if (seat > current && (smallestAbove == null || seat < smallestAbove)) {
      smallestAbove = seat;
    }
  }
  return smallestAbove ?? lowest;
}

void main() {
  group('C-590 D1 (a): two seats', () {
    test('[0, 2]: 0 -> 2', () => _expectNext('a', <int>[0, 2], 0, 2));
    test('[0, 2]: 2 wraps to 0', () => _expectNext('a', <int>[0, 2], 2, 0));
    test('[1, 3]: each seat names the other', () {
      _expectNext('a', <int>[1, 3], 1, 3);
      _expectNext('a', <int>[1, 3], 3, 1);
    });
  });

  group('C-590 D1 (b): three seats [0, 1, 2]', () {
    test('0 -> 1', () => _expectNext('b', <int>[0, 1, 2], 0, 1));
    test('1 -> 2', () => _expectNext('b', <int>[0, 1, 2], 1, 2));
    test('2 wraps to 0', () => _expectNext('b', <int>[0, 1, 2], 2, 0));
  });

  group('C-590 D1 (c): four seats [0, 1, 2, 3]', () {
    test('0 -> 1', () => _expectNext('c', <int>[0, 1, 2, 3], 0, 1));
    test('1 -> 2', () => _expectNext('c', <int>[0, 1, 2, 3], 1, 2));
    test('2 -> 3', () => _expectNext('c', <int>[0, 1, 2, 3], 2, 3));
    test('3 wraps to 0', () => _expectNext('c', <int>[0, 1, 2, 3], 3, 0));
  });

  group('C-590 D1: a table with a hole in it', () {
    test('[0, 2, 3]: 0 skips the empty seat 1 and reaches 2', () {
      _expectNext('hole', <int>[0, 2, 3], 0, 2);
    });
    test('[0, 2, 3]: 3 wraps to 0', () {
      _expectNext('hole', <int>[0, 2, 3], 3, 0);
    });
    test('[1, 2, 3]: 3 wraps to 1, the lowest, not to 0', () {
      _expectNext('hole', <int>[1, 2, 3], 3, 1);
    });
    test('[0, 1, 3]: 1 skips the empty seat 2 and reaches 3', () {
      _expectNext('hole', <int>[0, 1, 3], 1, 3);
    });
  });

  group('C-590 D1 (d): unsorted and duplicated input', () {
    test('[2, 0, 2, 1] from 2 wraps to 0', () {
      _expectNext('d', <int>[2, 0, 2, 1], 2, 0);
    });
    test('[2, 0, 2, 1] from 0 reaches 1, from 1 reaches 2', () {
      _expectNext('d', <int>[2, 0, 2, 1], 0, 1);
      _expectNext('d', <int>[2, 0, 2, 1], 1, 2);
    });
    test('[3, 3, 3, 1] is two distinct seats: 1 -> 3 and 3 -> 1', () {
      _expectNext('d dup', <int>[3, 3, 3, 1], 1, 3);
      _expectNext('d dup', <int>[3, 3, 3, 1], 3, 1);
    });
    test('[2, 2] is one distinct seat, so null', () {
      _expectNext('d dup-only', <int>[2, 2], 2, null);
    });
    test('the caller\'s list is neither sorted nor shrunk', () {
      final List<int> given = <int>[2, 0, 2, 1];
      nextSeatInPlay(given, 2);
      expect(
        given,
        <int>[2, 0, 2, 1],
        reason:
            'C-590 D1 (d): the function works on a copy; the argument '
            '[2, 0, 2, 1] came back as $given',
      );
    });
    test('an unmodifiable list is accepted (the copy is what gets sorted)', () {
      const List<int> frozen = <int>[2, 0, 1];
      expect(
        () => nextSeatInPlay(frozen, 2),
        returnsNormally,
        reason:
            'C-590 D1: sorting must happen on a copy; a const list '
            '[2, 0, 1] threw',
      );
      expect(nextSeatInPlay(frozen, 2), 0);
      final List<int> locked = List<int>.unmodifiable(<int>[3, 1, 0]);
      expect(nextSeatInPlay(locked, 1), 3);
    });
  });

  group('C-590 D1 (e): no answer', () {
    test(
      '[1] is a single seat: null',
      () => _expectNext('e', <int>[1], 1, null),
    );
    test('[] is no seat: null', () => _expectNext('e', <int>[], 0, null));
    test('[0, 2] with current 1 (not in the list): null', () {
      _expectNext('e', <int>[0, 2], 1, null);
    });
    test('current below, above and negative of every entry: null', () {
      _expectNext('e', <int>[1, 2, 3], 0, null);
      _expectNext('e', <int>[0, 1, 2], 3, null);
      _expectNext('e', <int>[0, 1, 2], -1, null);
    });
    test('a lone seat that is current: null, not itself', () {
      for (int seat = 0; seat < 4; seat++) {
        _expectNext('e', <int>[seat], seat, null);
      }
    });
  });

  group('C-590 D1: the whole 0..3 space, brute force', () {
    // Every non-empty subset of the four seats, handed over in a shuffled
    // order with a duplicate of its first member, against every current seat
    // from -1 to 4. Fixed enumeration, no seed.
    test('every subset, every current seat, shuffled with a duplicate', () {
      int checked = 0;
      for (int mask = 0; mask < 16; mask++) {
        final List<int> sorted = <int>[
          for (int seat = 0; seat < 4; seat++)
            if (mask & (1 << seat) != 0) seat,
        ];
        final List<int> shuffled = sorted.reversed.toList();
        if (sorted.isNotEmpty) {
          shuffled.add(sorted.first);
        }
        for (int current = -1; current <= 4; current++) {
          final int? want = _bruteForce(sorted, current);
          final int? got = nextSeatInPlay(shuffled, current);
          expect(
            got,
            want,
            reason:
                'C-590 D1: seats $sorted handed over as $shuffled with '
                'current $current: expected $want, got $got. Reproduce: '
                'nextSeatInPlay($shuffled, $current).',
          );
          checked += 1;
        }
      }
      expect(checked, 16 * 6);
    });

    test(
      'walking the order from any seat visits each seat once and returns',
      () {
        for (int mask = 0; mask < 16; mask++) {
          final List<int> sorted = <int>[
            for (int seat = 0; seat < 4; seat++)
              if (mask & (1 << seat) != 0) seat,
          ];
          if (sorted.length < 2) {
            continue;
          }
          for (final int start in sorted) {
            final List<int> visited = <int>[start];
            int? at = nextSeatInPlay(sorted, start);
            while (at != null &&
                at != start &&
                visited.length <= sorted.length) {
              visited.add(at);
              at = nextSeatInPlay(sorted, at);
            }
            expect(
              at,
              start,
              reason:
                  'C-590 D1: walking $sorted from $start never came back '
                  'to $start; visited $visited',
            );
            expect(
              visited.toSet().length,
              sorted.length,
              reason:
                  'C-590 D1: walking $sorted from $start visited $visited, '
                  'which is not every seat exactly once',
            );
          }
        }
      },
    );
  });
}
