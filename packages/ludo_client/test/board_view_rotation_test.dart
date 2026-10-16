// Widget tests for the viewer-seat board rotation (contract C-367 Part A,
// rules V2 and V3).
//
// Two points in the order text needed care when translating to widget
// assertions against lib/src/board.dart:
//   - Cases 5 and 6 name `board-token-hit-2-0` (when mySeat is 0) and
//     `board-token-hit-0-0` (when mySeat is 2 or null). In lib/src/board.dart,
//     `_tokenLayer` only builds `board-token-hit-<seat>-<index>` when
//     `seat == widget.mySeat`; every seat's token widget at the exact same
//     cell and fan centre carries `Key('token-<seat>-<index>')`. `_tokenFinder`
//     below prefers `board-token-hit-<seat>-<index>` whenever it is in the
//     tree and falls back to `token-<seat>-<index>` when it is not, so case 6
//     passes on main today and case 5 works whether or not order 373 adds hit
//     keys for non-viewer seats.
//   - Case 7 taps the centre of `board-token-hit-1-0` with mySeat 1 and
//     asserts `onTokenTap` receives 0 once. Because both `_tokenHitRect` and
//     `_handleTapUp` use unrotated cells on main today, tapping the finder's
//     current centre alone would tap the top-right yard and pass on main;
//     case 7 therefore also asserts that the tapped centre lies in the
//     bottom-left quarter of the board rect, so it fails on today's fixed
//     orientation and passes once both drawing and hit-testing rotate.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board.dart';

const _allSeats = <int>[0, 1, 2, 3];

Map<int, List<int>> _allInYard(List<int> seats) => <int, List<int>>{
  for (final seat in seats) seat: <int>[-1, -1, -1, -1],
};

Widget _harness({
  required Map<int, List<int>> tokens,
  List<int> seatsInPlay = _allSeats,
  int? mySeat,
  Set<int> legal = const <int>{},
  void Function(int token)? onTokenTap,
  TextDirection textDirection = TextDirection.ltr,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Directionality(
      textDirection: textDirection,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: LudoBoard(
              tokens: tokens,
              seatsInPlay: seatsInPlay,
              mySeat: mySeat,
              legal: legal,
              onTokenTap: onTokenTap,
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _tokenFinder(int seat, int tokenIndex) {
  final hit = find.byKey(Key('board-token-hit-$seat-$tokenIndex'));
  if (hit.evaluate().isNotEmpty) {
    return hit;
  }
  return find.byKey(Key('token-$seat-$tokenIndex'));
}

bool _inBottomLeftQuarter(Offset point, Rect board) =>
    point.dx >= board.left &&
    point.dx < board.center.dx &&
    point.dy > board.center.dy &&
    point.dy <= board.bottom;

bool _inTopRightQuarter(Offset point, Rect board) =>
    point.dx > board.center.dx &&
    point.dx <= board.right &&
    point.dy >= board.top &&
    point.dy < board.center.dy;

bool _inTopLeftQuarter(Offset point, Rect board) =>
    point.dx >= board.left &&
    point.dx < board.center.dx &&
    point.dy >= board.top &&
    point.dy < board.center.dy;

void main() {
  group('LudoBoard viewer-seat rotation (V2, V3)', () {
    testWidgets(
      'for each mySeat 0..3 with seatsInPlay [0, 1, 2, 3], the centre of '
      'board-token-hit-<mySeat>-0 is in the bottom-left quarter of the board',
      (tester) async {
        final tokens = _allInYard(_allSeats);
        for (final mySeat in _allSeats) {
          await tester.pumpWidget(_harness(tokens: tokens, mySeat: mySeat));
          await tester.pump();

          final boardRect = tester.getRect(find.byKey(const Key('ludo-board')));
          final hitFinder = find.byKey(Key('board-token-hit-$mySeat-0'));
          expect(hitFinder, findsOneWidget);
          final center = tester.getCenter(hitFinder);
          expect(
            _inBottomLeftQuarter(center, boardRect),
            isTrue,
            reason:
                'mySeat $mySeat: expected board-token-hit-$mySeat-0 centre '
                '$center to lie in the bottom-left quarter of $boardRect',
          );
        }
      },
    );

    testWidgets(
      'two players [0, 2]: opponent yard token 0 sits in the top-right '
      'quarter for both mySeat 0 and mySeat 2',
      (tester) async {
        const seats = <int>[0, 2];
        final tokens = _allInYard(seats);

        await tester.pumpWidget(
          _harness(tokens: tokens, seatsInPlay: seats, mySeat: 0),
        );
        await tester.pump();

        final boardRect0 = tester.getRect(find.byKey(const Key('ludo-board')));
        final oppFrom0 = _tokenFinder(2, 0);
        expect(oppFrom0, findsOneWidget);
        final center2 = tester.getCenter(oppFrom0);
        expect(
          _inTopRightQuarter(center2, boardRect0),
          isTrue,
          reason:
              'mySeat 0 with seatsInPlay [0, 2]: expected seat 2 token 0 '
              'centre $center2 in the top-right quarter of $boardRect0',
        );

        await tester.pumpWidget(
          _harness(tokens: tokens, seatsInPlay: seats, mySeat: 2),
        );
        await tester.pump();

        final boardRect2 = tester.getRect(find.byKey(const Key('ludo-board')));
        final oppFrom2 = _tokenFinder(0, 0);
        expect(oppFrom2, findsOneWidget);
        final center0 = tester.getCenter(oppFrom2);
        expect(
          _inTopRightQuarter(center0, boardRect2),
          isTrue,
          reason:
              'mySeat 2 with seatsInPlay [0, 2]: expected seat 0 token 0 '
              'centre $center0 in the top-right quarter of $boardRect2',
        );
      },
    );

    testWidgets('mySeat null keeps seat 0 token 0 in the top-left quarter', (
      tester,
    ) async {
      final tokens = _allInYard(_allSeats);
      await tester.pumpWidget(_harness(tokens: tokens));
      await tester.pump();

      final boardRect = tester.getRect(find.byKey(const Key('ludo-board')));
      final finder = _tokenFinder(0, 0);
      expect(finder, findsOneWidget);
      final center = tester.getCenter(finder);
      expect(
        _inTopLeftQuarter(center, boardRect),
        isTrue,
        reason:
            'mySeat null: expected seat 0 token 0 centre $center in the '
            'top-left quarter of $boardRect',
      );
    });

    testWidgets(
      'tapping the centre of board-token-hit-1-0 with mySeat 1 and legal {0} '
      'fires onTokenTap(0) exactly once',
      (tester) async {
        final tokens = _allInYard(_allSeats);
        final tapped = <int>[];

        await tester.pumpWidget(
          _harness(
            tokens: tokens,
            mySeat: 1,
            legal: const <int>{0},
            onTokenTap: tapped.add,
          ),
        );
        await tester.pump();

        final boardRect = tester.getRect(find.byKey(const Key('ludo-board')));
        final hitFinder = find.byKey(const Key('board-token-hit-1-0'));
        expect(hitFinder, findsOneWidget);
        final center = tester.getCenter(hitFinder);
        expect(
          _inBottomLeftQuarter(center, boardRect),
          isTrue,
          reason:
              'mySeat 1: expected board-token-hit-1-0 centre $center to lie '
              'in the bottom-left quarter of $boardRect before tapping',
        );

        await tester.tapAt(center);
        await tester.pump();

        expect(tapped, <int>[0]);
      },
    );

    testWidgets(
      'RTL Directionality does not mirror the rotated board for mySeat 0',
      (tester) async {
        final tokens = _allInYard(_allSeats);
        await tester.pumpWidget(
          _harness(tokens: tokens, mySeat: 0, textDirection: TextDirection.rtl),
        );
        await tester.pump();

        final boardRect = tester.getRect(find.byKey(const Key('ludo-board')));
        final hitFinder = find.byKey(const Key('board-token-hit-0-0'));
        expect(hitFinder, findsOneWidget);
        final center = tester.getCenter(hitFinder);
        expect(
          _inBottomLeftQuarter(center, boardRect),
          isTrue,
          reason:
              'under RTL with mySeat 0: expected board-token-hit-0-0 centre '
              '$center to remain in the bottom-left quarter of $boardRect',
        );
      },
    );
  });
}
