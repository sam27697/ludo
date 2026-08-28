// Acceptance tests for the board, written against docs/BOARD_API.md (the
// frozen spec at /tmp/BOARD_API.md) and docs/RULES.md section 1, without
// having read lib/src/board.dart. That file does not exist on this branch
// yet; these tests are expected to fail to compile until it lands.
//
// A few places in the spec did not resolve to a single reading. Rather than
// picking one and testing it silently, the choice made (and why) is noted
// at the point it matters, and the same points are reported to the master
// alongside this file. See in particular:
//   - property 6: the spec does not repeat "for any seat" the way property
//     5 does. Tested here for all four seats, as the more thorough reading.
//   - property 8: "the cell for its progress: 52..57" is ambiguous about
//     whether progress 57 contributes one cell (default tokenIndex) or four
//     (one per tokenIndex, as property 9 requires for distinguishing
//     finished tokens). Progress 57 is excluded from the rotation multiset
//     tested here; see the comment on that test.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart';

const _seats = [0, 1, 2, 3];
const _entry = [0, 13, 26, 39];

int _manhattan(BoardCell a, BoardCell b) =>
    (a.col - b.col).abs() + (a.row - b.row).abs();

int _chebyshev(BoardCell a, BoardCell b) =>
    math.max((a.col - b.col).abs(), (a.row - b.row).abs());

/// The name of the 6x6 corner quadrant [cell] falls in, or null if it is
/// outside all four. The board is 15x15; the cross arm through the middle
/// is 3 wide (columns and rows 6..8), leaving four 6x6 corners.
String? _cornerOf(BoardCell cell) {
  const corners = <String, (int, int, int, int)>{
    // (colLow, colHigh, rowLow, rowHigh)
    'top-left': (0, 5, 0, 5),
    'top-right': (9, 14, 0, 5),
    'bottom-right': (9, 14, 9, 14),
    'bottom-left': (0, 5, 9, 14),
  };
  for (final entry in corners.entries) {
    final (colLow, colHigh, rowLow, rowHigh) = entry.value;
    if (cell.col >= colLow &&
        cell.col <= colHigh &&
        cell.row >= rowLow &&
        cell.row <= rowHigh) {
      return entry.key;
    }
  }
  return null;
}

/// A 90-degree clockwise rotation about the board centre (7, 7), as given
/// verbatim by property 8.
BoardCell _rotate(BoardCell c) => BoardCell(14 - c.row, c.col);

Widget _harness({
  required Map<int, List<int>> tokens,
  List<int> seatsInPlay = const [0, 1, 2, 3],
  TextDirection textDirection = TextDirection.ltr,
}) {
  return MaterialApp(
    home: Directionality(
      textDirection: textDirection,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: LudoBoard(tokens: tokens, seatsInPlay: seatsInPlay),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('Range (property 1)', () {
    test('every seat, progress and tokenIndex combination stays inside the '
        '15x15 grid', () {
      for (final seat in _seats) {
        for (var progress = -1; progress <= 57; progress++) {
          for (var tokenIndex = 0; tokenIndex <= 3; tokenIndex++) {
            final cell = cellFor(
              seat: seat,
              progress: progress,
              tokenIndex: tokenIndex,
            );
            expect(
              cell.col >= 0 && cell.col <= 14,
              isTrue,
              reason:
                  'cellFor(seat: $seat, progress: $progress, '
                  'tokenIndex: $tokenIndex) returned col ${cell.col}, '
                  'outside 0..14',
            );
            expect(
              cell.row >= 0 && cell.row <= 14,
              isTrue,
              reason:
                  'cellFor(seat: $seat, progress: $progress, '
                  'tokenIndex: $tokenIndex) returned row ${cell.row}, '
                  'outside 0..14',
            );
          }
        }
      }
    });
  });

  group('The main track is a bijection (property 2)', () {
    test('seat 0, progress 0..51 gives 52 distinct cells', () {
      final seen = <BoardCell, int>{};
      final collisions = <String>[];
      for (var p = 0; p <= 51; p++) {
        final cell = cellFor(seat: 0, progress: p);
        final prior = seen[cell];
        if (prior != null) {
          collisions.add('progress $prior and progress $p both map to $cell');
        } else {
          seen[cell] = p;
        }
      }
      expect(
        collisions,
        isEmpty,
        reason:
            'expected 52 distinct cells for seat 0, progress 0..51; '
            'collisions found: ${collisions.join('; ')}',
      );
      expect(seen.length, 52);
    });
  });

  group('The track is connected (property 3)', () {
    // Amended 2026-08-28, run 15: Chebyshev distance exactly 1 for every
    // one of the 52 steps (orthogonal or diagonal), plus exactly four of
    // those 52 steps must be diagonal (Manhattan distance 2). Checking
    // Chebyshev alone would also pass a track that wandered diagonally
    // the whole way round, which is the wrong-direction bug this property
    // exists to catch, so both halves are asserted together.
    test('seat 0: progress p and p + 1 are adjacent (Chebyshev distance '
        'exactly 1) for every p in 0..50, wrapping progress 51 to progress '
        '0, and exactly four of those 52 steps are diagonal (Manhattan '
        'distance 2)', () {
      final steps = <int, (BoardCell, BoardCell)>{
        for (var p = 0; p <= 50; p++)
          p: (cellFor(seat: 0, progress: p), cellFor(seat: 0, progress: p + 1)),
        51: (cellFor(seat: 0, progress: 51), cellFor(seat: 0, progress: 0)),
      };

      final diagonalAt = <int>[];
      for (final entry in steps.entries) {
        final p = entry.key;
        final (a, b) = entry.value;
        final chebyshev = _chebyshev(a, b);
        expect(
          chebyshev,
          1,
          reason:
              'seat 0: progress $p ($a) and its successor ($b) are '
              'Chebyshev distance $chebyshev apart, expected exactly 1 '
              '(seed: p=$p)',
        );

        final manhattan = _manhattan(a, b);
        expect(
          manhattan == 1 || manhattan == 2,
          isTrue,
          reason:
              'seat 0: progress $p ($a) and its successor ($b) are '
              'Chebyshev distance 1 but Manhattan distance $manhattan, '
              'which is neither an orthogonal step (Manhattan 1) nor a '
              'diagonal one (Manhattan 2) (seed: p=$p)',
        );
        if (manhattan == 2) {
          diagonalAt.add(p);
        }
      }

      expect(
        diagonalAt.length,
        4,
        reason:
            'expected exactly 4 diagonal (Manhattan distance 2) steps '
            'around the 52-step track, one at each corner where an arm '
            'of the cross meets the next; found ${diagonalAt.length} at '
            'progress ${diagonalAt.join(', ')} (seed: diagonalAt='
            '$diagonalAt)',
      );
    });
  });

  group('The shared track is genuinely shared (property 4)', () {
    test('seat 0 progress 13 is the same cell as seat 1 progress 0, the '
        'concrete case the spec names', () {
      expect(
        cellFor(seat: 0, progress: 13),
        cellFor(seat: 1, progress: 0),
        reason:
            'seat 0 at progress 13 and seat 1 at progress 0 both sit on '
            'absolute square 13 (entry 0 + 13 == entry 13 + 0 mod 52) and '
            'must be the same cell; a mismatch here means seat 1\'s entry '
            'offset is wrong',
      );
    });

    test('every pair of seats and progresses landing on the same absolute '
        'square give the same cell', () {
      for (final a in _seats) {
        for (var pa = 0; pa <= 51; pa++) {
          final absolute = (_entry[a] + pa) % 52;
          final cellA = cellFor(seat: a, progress: pa);
          for (final b in _seats) {
            final pb = (absolute - _entry[b]) % 52;
            final cellB = cellFor(seat: b, progress: pb);
            expect(
              cellA,
              cellB,
              reason:
                  'seat $a progress $pa and seat $b progress $pb both '
                  'land on absolute square $absolute, but cellFor gave '
                  '$cellA and $cellB respectively (seed: a=$a pa=$pa '
                  'b=$b pb=$pb)',
            );
          }
        }
      }
    });
  });

  group('Home columns are private (property 5)', () {
    test('all 20 home-column cells (4 seats x 5 cells) are pairwise distinct '
        'and disjoint from every main-track cell', () {
      final mainTrack = <BoardCell, String>{};
      for (final seat in _seats) {
        for (var p = 0; p <= 51; p++) {
          mainTrack.putIfAbsent(
            cellFor(seat: seat, progress: p),
            () => 'seat $seat progress $p (main track)',
          );
        }
      }

      final home = <BoardCell, String>{};
      final collisions = <String>[];
      for (final seat in _seats) {
        for (var p = 52; p <= 56; p++) {
          final cell = cellFor(seat: seat, progress: p);
          final label = 'seat $seat progress $p';
          final priorHome = home[cell];
          if (priorHome != null) {
            collisions.add(
              '$label collides with home-column cell "$priorHome" at '
              '$cell',
            );
          } else {
            home[cell] = label;
          }
          final priorTrack = mainTrack[cell];
          if (priorTrack != null) {
            collisions.add(
              '$label collides with main-track cell "$priorTrack" at '
              '$cell',
            );
          }
        }
      }

      expect(collisions, isEmpty, reason: collisions.join('; '));
      expect(
        home.length,
        20,
        reason:
            'expected 4 seats x 5 home cells = 20 distinct cells, got '
            '${home.length}',
      );
    });
  });

  group('The home column is connected to the track (property 6)', () {
    // The spec states this without repeating "for any seat" the way
    // property 5 does. Tested for every seat here, as the more thorough
    // reading consistent with property 5's framing of the same subject;
    // reported as a point worth the master's confirmation.
    test('for every seat: progress 51 to 52 are adjacent, and 52..56 form a '
        'connected orthogonal path', () {
      for (final seat in _seats) {
        final chain = [
          for (var p = 51; p <= 56; p++)
            MapEntry(p, cellFor(seat: seat, progress: p)),
        ];
        for (var i = 0; i < chain.length - 1; i++) {
          final a = chain[i];
          final b = chain[i + 1];
          final distance = _manhattan(a.value, b.value);
          expect(
            distance,
            1,
            reason:
                'seat $seat: progress ${a.key} (${a.value}) and progress '
                '${b.key} (${b.value}) are Manhattan distance $distance '
                'apart, expected 1 (seed: seat=$seat, progress=${a.key})',
          );
        }
      }
    });
  });

  group('Yards are private and per-token (property 7)', () {
    test('each seat\'s four yard cells are distinct, share one 6x6 corner '
        'quadrant, and never coincide with a main-track, home-column or '
        'finished cell', () {
      final occupied = <BoardCell, String>{};
      for (final seat in _seats) {
        for (var p = 0; p <= 51; p++) {
          occupied.putIfAbsent(
            cellFor(seat: seat, progress: p),
            () => 'seat $seat progress $p (main track)',
          );
        }
        for (var p = 52; p <= 56; p++) {
          occupied.putIfAbsent(
            cellFor(seat: seat, progress: p),
            () => 'seat $seat progress $p (home column)',
          );
        }
        for (var t = 0; t <= 3; t++) {
          occupied.putIfAbsent(
            cellFor(seat: seat, progress: 57, tokenIndex: t),
            () => 'seat $seat progress 57 tokenIndex $t (finished)',
          );
        }
      }

      for (final seat in _seats) {
        final yard = [
          for (var t = 0; t <= 3; t++)
            cellFor(seat: seat, progress: -1, tokenIndex: t),
        ];

        expect(
          yard.toSet().length,
          4,
          reason:
              'seat $seat: expected 4 distinct yard cells for tokenIndex '
              '0..3, got $yard',
        );

        final corner = _cornerOf(yard.first);
        expect(
          corner,
          isNotNull,
          reason:
              'seat $seat tokenIndex 0 yard cell ${yard.first} is not '
              'inside any of the four 6x6 corner quadrants',
        );
        for (var t = 0; t < yard.length; t++) {
          expect(
            _cornerOf(yard[t]),
            corner,
            reason:
                'seat $seat: yard cells must share one corner quadrant; '
                'tokenIndex $t is at ${yard[t]} in corner '
                '${_cornerOf(yard[t])}, but tokenIndex 0 is in $corner '
                '(seed: seat=$seat, tokenIndex=$t)',
          );
        }

        for (var t = 0; t < yard.length; t++) {
          final cell = yard[t];
          expect(
            occupied.containsKey(cell),
            isFalse,
            reason:
                'seat $seat tokenIndex $t yard cell $cell also equals '
                '${occupied[cell]}, but yard cells must be private (seed: '
                'seat=$seat, tokenIndex=$t)',
          );
        }
      }
    });
  });

  group('The four seats are rotations of each other (property 8)', () {
    test('the rotation formula fixes the centre and cycles the four corners '
        'clockwise', () {
      expect(_rotate(const BoardCell(7, 7)), const BoardCell(7, 7));
      expect(_rotate(const BoardCell(0, 0)), const BoardCell(14, 0));
      expect(_rotate(const BoardCell(14, 0)), const BoardCell(14, 14));
      expect(_rotate(const BoardCell(14, 14)), const BoardCell(0, 14));
      expect(_rotate(const BoardCell(0, 14)), const BoardCell(0, 0));
    });

    test(
      'seat s\'s yard (tokenIndex 0..3) plus home column (progress 52..56) '
      'is the clockwise rotation of seat s-1\'s, wrapping seat 0 to seat 3 -- '
      'progress 57 is deliberately excluded from this multiset. The spec '
      'says the rotation covers "the cell for its progress: 52..57" '
      '(singular "the cell"), but property 9 requires tokenIndex to '
      'distinguish four separate finished cells at progress 57, and it is '
      'not stated whether the rotation multiset takes one of those (default '
      'tokenIndex) or all four. Reported to the master rather than guessed.',
      () {
        List<BoardCell> multisetFor(int seat) => [
          for (var t = 0; t <= 3; t++)
            cellFor(seat: seat, progress: -1, tokenIndex: t),
          for (var p = 52; p <= 56; p++) cellFor(seat: seat, progress: p),
        ];

        int cmp(BoardCell a, BoardCell b) =>
            a.col != b.col ? a.col - b.col : a.row - b.row;

        for (final seat in _seats) {
          final previous = (seat + 3) % 4;
          final expected = multisetFor(previous).map(_rotate).toList()
            ..sort(cmp);
          final actual = multisetFor(seat).toList()..sort(cmp);
          expect(
            actual,
            expected,
            reason:
                'seat $seat: yard+home-column multiset $actual is not the '
                'clockwise rotation of seat $previous\'s ($expected) (seed: '
                'seat=$seat, previous=$previous)',
          );
        }
      },
    );
  });

  group('progress 57 is the centre (property 9)', () {
    test('every seat\'s four finished cells sit in the 3x3 centre block and '
        'tokenIndex distinguishes them within that seat', () {
      for (final seat in _seats) {
        final finished = [
          for (var t = 0; t <= 3; t++)
            cellFor(seat: seat, progress: 57, tokenIndex: t),
        ];
        for (var t = 0; t < finished.length; t++) {
          final cell = finished[t];
          expect(
            cell.col >= 6 && cell.col <= 8,
            isTrue,
            reason:
                'seat $seat tokenIndex $t finished cell $cell has col '
                'outside 6..8',
          );
          expect(
            cell.row >= 6 && cell.row <= 8,
            isTrue,
            reason:
                'seat $seat tokenIndex $t finished cell $cell has row '
                'outside 6..8',
          );
        }
        expect(
          finished.toSet().length,
          4,
          reason:
              'seat $seat: expected tokenIndex 0..3 to give 4 distinct '
              'finished cells within that seat, got $finished',
        );
      }
    });
  });

  group('Purity (property 10)', () {
    test('every seat/progress/tokenIndex combination gives the same answer '
        'on a second call', () {
      for (final seat in _seats) {
        for (var progress = -1; progress <= 57; progress++) {
          for (var tokenIndex = 0; tokenIndex <= 3; tokenIndex++) {
            final first = cellFor(
              seat: seat,
              progress: progress,
              tokenIndex: tokenIndex,
            );
            final second = cellFor(
              seat: seat,
              progress: progress,
              tokenIndex: tokenIndex,
            );
            expect(
              second,
              first,
              reason:
                  'cellFor(seat: $seat, progress: $progress, tokenIndex: '
                  '$tokenIndex) gave $first on the first call and $second '
                  'on the second (seed: seat=$seat, progress=$progress, '
                  'tokenIndex=$tokenIndex)',
            );
          }
        }
      }
    });

    test('a previously returned cell does not change after unrelated calls '
        'are made, ruling out shared mutable state', () {
      final before = cellFor(seat: 0, progress: 10);
      final beforeCol = before.col;
      final beforeRow = before.row;

      for (final seat in _seats) {
        for (var progress = -1; progress <= 57; progress++) {
          for (var tokenIndex = 0; tokenIndex <= 3; tokenIndex++) {
            cellFor(seat: seat, progress: progress, tokenIndex: tokenIndex);
          }
        }
      }

      expect(
        before.col,
        beforeCol,
        reason:
            'seat 0 progress 10: col read as $beforeCol at first, but is '
            'now ${before.col} after making unrelated calls -- this would '
            'mean the returned cell aliases mutable shared state',
      );
      expect(
        before.row,
        beforeRow,
        reason:
            'seat 0 progress 10: row read as $beforeRow at first, but is '
            'now ${before.row} after making unrelated calls -- this would '
            'mean the returned cell aliases mutable shared state',
      );
      expect(
        cellFor(seat: 0, progress: 10),
        before,
        reason:
            'calling cellFor(seat: 0, progress: 10) again after many '
            'unrelated calls gave a different answer than the original '
            'call',
      );
    });
  });

  group('cellFor rejects out-of-range arguments with ArgumentError', () {
    test('seat outside 0..3 throws ArgumentError', () {
      expect(
        () => cellFor(seat: -1, progress: 0),
        throwsArgumentError,
        reason: 'seat -1 is outside 0..3 and must throw ArgumentError',
      );
      expect(
        () => cellFor(seat: 4, progress: 0),
        throwsArgumentError,
        reason: 'seat 4 is outside 0..3 and must throw ArgumentError',
      );
    });

    test('progress outside -1..57 throws ArgumentError', () {
      expect(
        () => cellFor(seat: 0, progress: -2),
        throwsArgumentError,
        reason: 'progress -2 is outside -1..57 and must throw ArgumentError',
      );
      expect(
        () => cellFor(seat: 0, progress: 58),
        throwsArgumentError,
        reason: 'progress 58 is outside -1..57 and must throw ArgumentError',
      );
    });

    test('tokenIndex outside 0..3 throws ArgumentError, including where '
        'progress 0..56 would otherwise ignore it entirely', () {
      // The spec's Errors section states tokenIndex validation
      // unconditionally ("ArgumentError for ... tokenIndex outside
      // 0..3"), separately from the "ignored entirely for progress in
      // 0..56" rule about the *result*. Read literally, an invalid
      // tokenIndex must still be rejected even on a progress where it
      // would not have affected the answer -- reject, never repair,
      // per the same "Errors" section.
      expect(
        () => cellFor(seat: 0, progress: 10, tokenIndex: -1),
        throwsArgumentError,
        reason:
            'tokenIndex -1 must be rejected even though progress 10 is '
            'in the range where tokenIndex is otherwise ignored',
      );
      expect(
        () => cellFor(seat: 0, progress: 10, tokenIndex: 4),
        throwsArgumentError,
        reason:
            'tokenIndex 4 must be rejected even though progress 10 is '
            'in the range where tokenIndex is otherwise ignored',
      );
      expect(
        () => cellFor(seat: 0, progress: -1, tokenIndex: -1),
        throwsArgumentError,
        reason: 'tokenIndex -1 at progress -1 (yard) must be rejected',
      );
      expect(
        () => cellFor(seat: 0, progress: -1, tokenIndex: 4),
        throwsArgumentError,
        reason: 'tokenIndex 4 at progress -1 (yard) must be rejected',
      );
      expect(
        () => cellFor(seat: 0, progress: 57, tokenIndex: -1),
        throwsArgumentError,
        reason: 'tokenIndex -1 at progress 57 (finished) must be rejected',
      );
      expect(
        () => cellFor(seat: 0, progress: 57, tokenIndex: 4),
        throwsArgumentError,
        reason: 'tokenIndex 4 at progress 57 (finished) must be rejected',
      );
    });

    test('the thrown error is exactly an ArgumentError', () {
      expect(
        () => cellFor(seat: -1, progress: 0),
        throwsA(isA<ArgumentError>()),
        reason:
            'the spec is explicit that this is ArgumentError, not an '
            'assertion, not a clamp and not a null',
      );
    });
  });

  group('BoardCell value semantics', () {
    test('equality is by value', () {
      expect(const BoardCell(3, 5), const BoardCell(3, 5));
      expect(const BoardCell(3, 5) == const BoardCell(5, 3), isFalse);
      expect(const BoardCell(3, 5) == const BoardCell(3, 6), isFalse);
    });

    test('equality against an unrelated object is false, not a throw', () {
      final other = Object();
      expect(const BoardCell(1, 2) == other, isFalse);
    });

    test('hashCode is consistent with equality', () {
      const a = BoardCell(9, 2);
      const b = BoardCell(9, 2);
      expect(
        a.hashCode,
        b.hashCode,
        reason: 'equal BoardCells ($a, $b) must have equal hashCode',
      );
    });

    test('usable as a Set element, deduplicating equal cells', () {
      final set = <BoardCell>{
        const BoardCell(1, 2),
        const BoardCell(1, 2),
        const BoardCell(3, 4),
      };
      expect(
        set.length,
        2,
        reason:
            'expected the duplicate BoardCell(1, 2) to be deduplicated, got $set',
      );
      expect(set.contains(const BoardCell(1, 2)), isTrue);
      expect(set.contains(const BoardCell(3, 4)), isTrue);
    });

    test('usable as a Map key', () {
      final map = <BoardCell, String>{
        const BoardCell(1, 2): 'a',
        const BoardCell(3, 4): 'b',
      };
      expect(map[const BoardCell(1, 2)], 'a');
      expect(map[const BoardCell(3, 4)], 'b');
      expect(map[const BoardCell(5, 6)], isNull);
    });

    test('toString is exactly "BoardCell(col, row)"', () {
      expect(const BoardCell(0, 0).toString(), 'BoardCell(0, 0)');
      expect(const BoardCell(14, 7).toString(), 'BoardCell(14, 7)');
      expect(const BoardCell(3, 12).toString(), 'BoardCell(3, 12)');
    });
  });

  group('LudoBoard widget', () {
    testWidgets(
      'a four-seat board renders one token widget per seat per token index',
      (tester) async {
        final tokens = {
          for (final seat in _seats) seat: [-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(tokens: tokens));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ludo-board')), findsOneWidget);

        for (final seat in _seats) {
          for (var index = 0; index <= 3; index++) {
            expect(
              find.byKey(Key('token-$seat-$index')),
              findsOneWidget,
              reason:
                  'expected exactly one widget with key token-$seat-$index '
                  'for a four-seat board (seed: seat=$seat, index=$index)',
            );
          }
        }
      },
    );

    testWidgets(
      'a two-seat board with seatsInPlay [0, 2] renders 8 tokens and none '
      'for seats 1 or 3',
      (tester) async {
        final tokens = {
          0: [-1, -1, -1, -1],
          2: [-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(tokens: tokens, seatsInPlay: const [0, 2]),
        );
        await tester.pumpAndSettle();

        for (final seat in [0, 2]) {
          for (var index = 0; index <= 3; index++) {
            expect(
              find.byKey(Key('token-$seat-$index')),
              findsOneWidget,
              reason:
                  'seat $seat is in seatsInPlay: expected token-$seat-'
                  '$index (seed: seat=$seat, index=$index)',
            );
          }
        }

        for (final seat in [1, 3]) {
          for (var index = 0; index <= 3; index++) {
            expect(
              find.byKey(Key('token-$seat-$index')),
              findsNothing,
              reason:
                  'seat $seat is not in seatsInPlay [0, 2]: expected no '
                  'token-$seat-$index widget, but one was found (seed: '
                  'seat=$seat, index=$index)',
            );
          }
        }
      },
    );

    testWidgets(
      'every token\'s Semantics identifier matches what cellFor returns '
      'for its seat, token index and progress',
      (tester) async {
        final tokens = {
          0: [-1, 0, 25, 57],
          1: [13, 52, -1, 40],
          2: [26, 56, 51, -1],
          3: [39, 0, 57, 30],
        };
        final handle = tester.ensureSemantics();
        addTearDown(handle.dispose);

        await tester.pumpWidget(_harness(tokens: tokens));
        await tester.pumpAndSettle();

        for (final seat in _seats) {
          for (var index = 0; index <= 3; index++) {
            final progress = tokens[seat]![index];
            final expected = cellFor(
              seat: seat,
              progress: progress,
              tokenIndex: index,
            );
            final expectedId = 'cell-${expected.col}-${expected.row}';
            expect(
              find.descendant(
                of: find.byKey(Key('token-$seat-$index')),
                matching: find.bySemanticsIdentifier(expectedId),
                matchRoot: true,
              ),
              findsOneWidget,
              reason:
                  'token-$seat-$index (progress $progress) should carry '
                  'Semantics(identifier: "$expectedId") per '
                  'cellFor(seat: $seat, progress: $progress, tokenIndex: '
                  '$index), but it was not found (seed: seat=$seat, '
                  'index=$index, progress=$progress)',
            );
          }
        }
      },
    );

    testWidgets(
      'two tokens of the same seat on the same progress in 0..56 resolve '
      'to the same cell identifier',
      (tester) async {
        final tokens = {
          for (final seat in _seats) seat: [10, 10, 30, 45],
        };
        final handle = tester.ensureSemantics();
        addTearDown(handle.dispose);

        await tester.pumpWidget(_harness(tokens: tokens));
        await tester.pumpAndSettle();

        for (final seat in _seats) {
          final expected = cellFor(seat: seat, progress: 10);
          final expectedId = 'cell-${expected.col}-${expected.row}';
          expect(
            find.descendant(
              of: find.byKey(Key('token-$seat-0')),
              matching: find.bySemanticsIdentifier(expectedId),
              matchRoot: true,
            ),
            findsOneWidget,
            reason:
                'seat $seat token index 0 is at progress 10, expected '
                'identifier $expectedId',
          );
          expect(
            find.descendant(
              of: find.byKey(Key('token-$seat-1')),
              matching: find.bySemanticsIdentifier(expectedId),
              matchRoot: true,
            ),
            findsOneWidget,
            reason:
                'seat $seat token index 1 is also at progress 10 and '
                'should share identifier $expectedId with token index 0, '
                'since cellFor ignores tokenIndex for progress in 0..56 '
                '(seed: seat=$seat)',
          );
        }
      },
    );

    testWidgets(
      'the board renders identical cell identifiers under an RTL locale',
      (tester) async {
        final tokens = {
          0: [-1, 0, 25, 57],
          1: [13, 52, -1, 40],
          2: [26, 56, 51, -1],
          3: [39, 0, 57, 30],
        };
        final handle = tester.ensureSemantics();
        addTearDown(handle.dispose);

        await tester.pumpWidget(
          _harness(tokens: tokens, textDirection: TextDirection.rtl),
        );
        await tester.pumpAndSettle();

        for (final seat in _seats) {
          for (var index = 0; index <= 3; index++) {
            final progress = tokens[seat]![index];
            final expected = cellFor(
              seat: seat,
              progress: progress,
              tokenIndex: index,
            );
            final expectedId = 'cell-${expected.col}-${expected.row}';
            expect(
              find.descendant(
                of: find.byKey(Key('token-$seat-$index')),
                matching: find.bySemanticsIdentifier(expectedId),
                matchRoot: true,
              ),
              findsOneWidget,
              reason:
                  'under RTL, token-$seat-$index should still carry '
                  'identifier "$expectedId" -- mirroring for RTL is the '
                  'renderer\'s business and must not change board-space '
                  'cell numbers (seed: seat=$seat, index=$index, '
                  'progress=$progress)',
            );
          }
        }
      },
    );

    testWidgets('renders with no network and no pending timers or tickers', (
      tester,
    ) async {
      final tokens = {
        for (final seat in _seats) seat: [-1, -1, -1, -1],
      };

      await tester.pumpWidget(_harness(tokens: tokens));
      await tester.pumpAndSettle();

      expect(
        SchedulerBinding.instance.transientCallbackCount,
        0,
        reason:
            'a ticker or animation is still scheduled after '
            'pumpAndSettle; the board must be a pure function of its '
            'arguments with no timers or animation controllers',
      );
      // A leftover dart:async Timer would independently fail this test
      // at teardown, since flutter_test's binding refuses to complete a
      // test that still has a pending Timer.
    });
  });
}
