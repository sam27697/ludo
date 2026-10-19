// Acceptance tests for work/ludo/orders/C-408-ring-waits-for-the-token.md,
// written from that contract's text alone, against LudoBoard
// (lib/src/board.dart) as it stands on main a4246e5 -- before order 409's
// fix. The ring and glow gating C-408 asks for does not exist on that base
// (board.dart:1480-1508 places `board-legal-ring-S-T` at the token's truth
// position unconditionally whenever the token is legal, with no check of
// whether the drawn disc has actually arrived there), so every case the
// order marks "must be red on base" is expected to fail to compile-and-pass
// for that reason, not a typo in this file.
//
// Driven the way test/token_travel_test.dart drives a move: a small host
// StatefulWidget holds the tokens map behind a GlobalKey, a case calls
// setTokens(...) to hand the board a fresh snapshot the way a screen would,
// and the clock is stepped by exact kTokenStepDuration (or
// kTokenStepDurationReduced) amounts -- never pumpAndSettle, since a legal
// ring's pulse never settles. Every mount is fresh; no case reuses another
// case's widget tree.
//
// Two of the fixtures below (case 5's hurried queue and case 6's shared
// landing square) were checked against the real widget before any
// assertion was written, by printing the drawn centre and the ring's
// presence at each step boundary -- not by reading board.dart's source and
// restating it, but to confirm which specific instants are unambiguously
// "mid-travel" by the override/truth mismatch the contract itself defines,
// since C-408 does not touch that bookkeeping and this file must not
// invent a disagreement with it. Case 5's own comment says exactly what
// that printing found and the one instant this file deliberately does not
// assert about, and why.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';

const List<int> _seats = <int>[0, 1, 2, 3];
const double _boardSide = 400;
const double _cellSize = _boardSide / 15;

/// All four seats, each with four tokens sitting in their own yard
/// (progress -1). The default fixture for a case that only names the
/// tokens it actually moves.
Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in _seats) seat: <int>[-1, -1, -1, -1],
};

/// The centre board.dart's `_tokenLayer` draws token [tokenIndex] of [seat]
/// at, when it sits still at [progress] and is the only occupant of its
/// cell: `toView` of `cellFor`'s cell centre under `viewQuarters(mySeat)`
/// plus the fan offset `_tokenLayer` documents (`cellSize * 0.12`, negated
/// for an even index on one axis, negated again for index < 2 on the
/// other). Mirrors board.dart's own math rather than inventing a second
/// formula that could silently disagree with the widget under test, the
/// same reasoning test/token_travel_test.dart's identical helper gives.
Offset _expectedFanCenter({
  required int seat,
  required int tokenIndex,
  required int progress,
  int? mySeat,
}) {
  final BoardCell cell = toView(
    cellFor(seat: seat, progress: progress, tokenIndex: tokenIndex),
    viewQuarters(mySeat),
  );
  final double fan = _cellSize * 0.12;
  final double fanDx = tokenIndex.isEven ? -fan : fan;
  final double fanDy = tokenIndex < 2 ? -fan : fan;
  return Offset(
    cell.col * _cellSize + _cellSize / 2 + fanDx,
    cell.row * _cellSize + _cellSize / 2 + fanDy,
  );
}

/// The centre board.dart's `_tokenLayout` gives a main-track cell shared by
/// two to four occupants: the cell centre plus `(dx, dy) * cellSize * 0.22`
/// for the occupant's slot in `_sharedQuad` order ((-1,-1), (1,-1), (-1,1),
/// (1,1)). [slot] is the occupant's position in that order -- other seats
/// before the viewer's own, ascending by rank, documented at
/// `_occupantsOnCell`'s own comment -- not a value this file is free to
/// pick, since getting it wrong would make a correct board fail here.
Offset _expectedSharedCenter({
  required int seat,
  required int tokenIndex,
  required int progress,
  required int slot,
  int? mySeat,
}) {
  final BoardCell cell = toView(
    cellFor(seat: seat, progress: progress, tokenIndex: tokenIndex),
    viewQuarters(mySeat),
  );
  const List<(int, int)> sharedQuad = <(int, int)>[
    (-1, -1),
    (1, -1),
    (-1, 1),
    (1, 1),
  ];
  final (int sx, int sy) = sharedQuad[slot];
  return Offset(
    cell.col * _cellSize + _cellSize / 2 + sx * _cellSize * 0.22,
    cell.row * _cellSize + _cellSize / 2 + sy * _cellSize * 0.22,
  );
}

/// The board's top-left corner in the test window, the same way
/// test/token_travel_test.dart reads it: every measured or expected
/// position is taken relative to this.
Offset _boardOrigin(WidgetTester tester) =>
    tester.getTopLeft(find.byType(LudoBoard));

/// Asserts the drawn token-[seat]-[tokenIndex] widget is centred on
/// [expected] (already in board coordinates), within 0.5 logical pixels,
/// this order's named slack. [because] folds the moment being checked and
/// every number needed to reproduce it into the failure message.
void _expectCenterNear(
  WidgetTester tester, {
  required Key key,
  required Offset expected,
  required String because,
}) {
  final Offset actual =
      tester.getCenter(find.byKey(key)) - _boardOrigin(tester);
  final double distance = (actual - expected).distance;
  expect(
    distance <= 0.5,
    isTrue,
    reason:
        '$because: ${key.toString()} should be centred on $expected, '
        'actual centre is $actual, distance '
        '${distance.toStringAsFixed(3)}px',
  );
}

void _expectNoRing(
  WidgetTester tester, {
  required int seat,
  required int token,
  required String because,
}) {
  expect(
    find.byKey(Key('board-legal-ring-$seat-$token')),
    findsNothing,
    reason:
        '$because: board-legal-ring-$seat-$token must be absent from the '
        'tree (seed: seat=$seat, token=$token)',
  );
}

void _expectRing(
  WidgetTester tester, {
  required int seat,
  required int token,
  required String because,
}) {
  expect(
    find.byKey(Key('board-legal-ring-$seat-$token')),
    findsOneWidget,
    reason:
        '$because: board-legal-ring-$seat-$token must be present in the '
        'tree (seed: seat=$seat, token=$token)',
  );
}

void _expectNoGlow(
  WidgetTester tester, {
  required int seat,
  required int token,
  required String because,
}) {
  expect(
    find.byKey(Key('board-automove-glow-$seat-$token')),
    findsNothing,
    reason:
        '$because: board-automove-glow-$seat-$token must be absent from '
        'the tree (seed: seat=$seat, token=$token)',
  );
}

/// Holds one [LudoBoard]'s `tokens` across rebuilds so a case can call
/// setTokens(...) through a GlobalKey the way a screen hands the board a
/// fresh server snapshot. `legal` and `autoMoveToken` are fixed for the
/// life of one mount -- no case in this file needs to change which tokens
/// are legal mid-test, only which square they occupy.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.tokens,
    this.mySeat,
    this.legal = const <int>{},
    this.autoMoveToken,
  });

  final Map<int, List<int>> tokens;
  final int? mySeat;
  final Set<int> legal;
  final int? autoMoveToken;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Map<int, List<int>> _tokens;

  @override
  void initState() {
    super.initState();
    _tokens = widget.tokens;
  }

  void setTokens(Map<int, List<int>> next) {
    setState(() {
      _tokens = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LudoBoard(
      tokens: _tokens,
      seatsInPlay: _seats,
      mySeat: widget.mySeat,
      legal: widget.legal,
      autoMoveToken: widget.autoMoveToken,
    );
  }
}

/// Mounts [_Host] under a MaterialApp with the app's own localization
/// delegates (needed whenever `mySeat` is set, since board.dart's hit
/// target reads AppLocalizations), inside a fixed [_boardSide] square box
/// -- the same harness shape test/board_test.dart, test/board_seat_
/// identity_test.dart and test/token_travel_test.dart all use.
Widget _harness({
  required GlobalKey<_HostState> hostKey,
  required Map<int, List<int>> tokens,
  int? mySeat,
  Set<int> legal = const <int>{},
  int? autoMoveToken,
  bool disableAnimations = false,
  Locale locale = const Locale('en'),
}) {
  final Widget host = _Host(
    key: hostKey,
    tokens: tokens,
    mySeat: mySeat,
    legal: legal,
    autoMoveToken: autoMoveToken,
  );
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _boardSide,
          height: _boardSide,
          child: disableAnimations
              ? Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: host,
                  ),
                )
              : host,
        ),
      ),
    ),
  );
}

void main() {
  group(
    'Case 1 (decision 1, ring): a legal mover carries no ring mid-travel',
    () {
      testWidgets(
        'token 0 of seat 0 moves progress 2 -> 6 (steps to 3, 4, 5, 6): no '
        'board-legal-ring-0-0 right after the rebuild or at steps 1, 2 and 3',
        (tester) async {
          final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
          final Map<int, List<int>> before = <int, List<int>>{
            0: <int>[2, -1, -1, -1],
            1: <int>[-1, -1, -1, -1],
            2: <int>[-1, -1, -1, -1],
            3: <int>[-1, -1, -1, -1],
          };
          await tester.pumpWidget(
            _harness(
              hostKey: hostKey,
              tokens: before,
              mySeat: 0,
              legal: const <int>{0},
            ),
          );
          await tester.pump();

          hostKey.currentState!.setTokens(<int, List<int>>{
            0: <int>[6, -1, -1, -1],
            1: <int>[-1, -1, -1, -1],
            2: <int>[-1, -1, -1, -1],
            3: <int>[-1, -1, -1, -1],
          });
          await tester.pump();
          _expectNoRing(
            tester,
            seat: 0,
            token: 0,
            because:
                'immediately after the rebuild that moves token 0 from 2 to '
                '6, the disc is still drawn on the cell of 2 (truth is 6)',
          );

          // Steps 1, 2 and 3 of the 4-step path: at least one step pumped,
          // at least one step still left -- decision 1's "mid-travel".
          for (final int step in <int>[1, 2, 3]) {
            await tester.pump(kTokenStepDuration);
            _expectNoRing(
              tester,
              seat: 0,
              token: 0,
              because:
                  'step $step of 4 in the move from progress 2 to 6: the '
                  'disc has not yet reached truth (progress 6)',
            );
          }
        },
      );
    },
  );

  group(
    'Case 2 (decision 1, glow): the same move, the unique auto-move glow',
    () {
      testWidgets(
        'token 0 of seat 0 moves progress 2 -> 6, the unique legal and '
        'auto-move token: no board-automove-glow-0-0 right after the '
        'rebuild or at steps 1, 2 and 3',
        (tester) async {
          final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
          final Map<int, List<int>> before = <int, List<int>>{
            0: <int>[2, -1, -1, -1],
            1: <int>[-1, -1, -1, -1],
            2: <int>[-1, -1, -1, -1],
            3: <int>[-1, -1, -1, -1],
          };
          await tester.pumpWidget(
            _harness(
              hostKey: hostKey,
              tokens: before,
              mySeat: 0,
              legal: const <int>{0},
              autoMoveToken: 0,
            ),
          );
          await tester.pump();

          hostKey.currentState!.setTokens(<int, List<int>>{
            0: <int>[6, -1, -1, -1],
            1: <int>[-1, -1, -1, -1],
            2: <int>[-1, -1, -1, -1],
            3: <int>[-1, -1, -1, -1],
          });
          await tester.pump();
          _expectNoGlow(
            tester,
            seat: 0,
            token: 0,
            because:
                'immediately after the rebuild that moves the unique legal '
                'token from progress 2 to 6, before any step',
          );

          for (final int step in <int>[1, 2, 3]) {
            await tester.pump(kTokenStepDuration);
            _expectNoGlow(
              tester,
              seat: 0,
              token: 0,
              because:
                  'step $step of 4 in the unique-legal move from progress 2 '
                  'to 6: the disc has not yet reached truth',
            );
          }
        },
      );
    },
  );

  group(
    'Case 3 (decision 1, out of the yard): no ring while on the way in',
    () {
      testWidgets(
        'token 1 of seat 0 moves from the yard (-1) to progress 0, legal: '
        '[1]: no board-legal-ring-0-1 while the disc is still drawn in the '
        'yard, before the single step lands',
        (tester) async {
          final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
          final Map<int, List<int>> before = _allInYard();
          await tester.pumpWidget(
            _harness(
              hostKey: hostKey,
              tokens: before,
              mySeat: 0,
              legal: const <int>{1},
            ),
          );
          await tester.pump();

          hostKey.currentState!.setTokens(<int, List<int>>{
            0: <int>[-1, 0, -1, -1],
            1: <int>[-1, -1, -1, -1],
            2: <int>[-1, -1, -1, -1],
            3: <int>[-1, -1, -1, -1],
          });
          await tester.pump();
          // The yard-exit path is a single step (board.dart's `_pathFor`
          // returns the one square of progress 0 regardless of how far the
          // roll would otherwise carry a token already on the track), so
          // this is the only instant between the rebuild and the disc's
          // arrival: there is no later "mid-travel" boundary to also check.
          _expectNoRing(
            tester,
            seat: 0,
            token: 1,
            because:
                'right after leaving the yard, the disc for token 1 is '
                'still drawn in the yard (truth is already progress 0)',
          );
        },
      );
    },
  );

  group('Case 4 (decision 2): the ring arrives with the disc', () {
    testWidgets('token 0 of seat 0 moves progress 2 -> 6: after the last step, '
        'board-legal-ring-0-0 is present and centred on token-0-0\'s centre', (
      tester,
    ) async {
      final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
      final Map<int, List<int>> before = <int, List<int>>{
        0: <int>[2, -1, -1, -1],
        1: <int>[-1, -1, -1, -1],
        2: <int>[-1, -1, -1, -1],
        3: <int>[-1, -1, -1, -1],
      };
      await tester.pumpWidget(
        _harness(
          hostKey: hostKey,
          tokens: before,
          mySeat: 0,
          legal: const <int>{0},
        ),
      );
      await tester.pump();

      hostKey.currentState!.setTokens(<int, List<int>>{
        0: <int>[6, -1, -1, -1],
        1: <int>[-1, -1, -1, -1],
        2: <int>[-1, -1, -1, -1],
        3: <int>[-1, -1, -1, -1],
      });
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(kTokenStepDuration);
      }

      _expectRing(
        tester,
        seat: 0,
        token: 0,
        because: 'the fourth and last step has landed on progress 6',
      );

      final Offset ringCenter = tester.getCenter(
        find.byKey(const Key('board-legal-ring-0-0')),
      );
      final Offset tokenCenter = tester.getCenter(
        find.byKey(const Key('token-0-0')),
      );
      final double distance = (ringCenter - tokenCenter).distance;
      expect(
        distance <= 0.5,
        isTrue,
        reason:
            'after the move from progress 2 to 6 lands, the ring '
            'centre $ringCenter must match the drawn disc centre '
            '$tokenCenter within 0.5px, distance '
            '${distance.toStringAsFixed(3)}px',
      );
    });
  });

  group('Case 5 (decision 2 and 5, hurried queue): no ring until the whole '
      'queued travel ends', () {
    // A diagnostic print pass against this exact fixture (not committed)
    // showed the drawn centre at each boundary below. Between the moment
    // the first leg's last step timer fires and the moment the second
    // leg's own first step timer fires, board.dart's `_onMoveArrived`
    // clears the travel override for this (seat, token) key -- unwrapped
    // in any setState of its own -- while the second leg is still only
    // sitting in the queue; the very next frame therefore briefly reads
    // the disc's drawn position as truth's final value (progress 7)
    // before the second leg has played a single one of its own steps,
    // then the following step pulls it back to progress 5. That one
    // frame is a genuine mismatch between this contract's plain-English
    // "no ring until the second travel ends" and the letter of decision 2
    // ("the ring appears ... the frame the disc reaches its truth"), both
    // of which are satisfied by an implementation that gates strictly on
    // override-absence -- decision 2 would say the ring is allowed to
    // show for that one frame, the summary says it should not. This file
    // does not assert either way about that one frame; every other
    // boundary below is unambiguous and is asserted.
    testWidgets(
      'token 0 of seat 0: progress 2 -> 4 (first leg), then 4 -> 7 queued '
      'before the first leg finishes: no ring until the combined travel '
      'truly lands on 7',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[4, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'first leg (2 -> 4) just started, before its first step',
        );

        await tester.pump(kTokenStepDuration);
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'first leg\'s first step (drawn progress 3, truth 4)',
        );

        // The second leg is queued while the first leg's last step is
        // still pending -- "before the first finishes".
        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because:
              'second leg (4 -> 7) just queued behind the first leg, '
              'which has not yet landed',
        );

        // The first leg's last step lands here; this is the one frame
        // this file does not assert about (see the group comment above).
        await tester.pump(kTokenStepDuration);

        await tester.pump(kTokenStepDuration);
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'second leg\'s own first step (drawn progress 5, truth 7)',
        );

        await tester.pump(kTokenStepDuration);
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'second leg\'s second step (drawn progress 6, truth 7)',
        );

        await tester.pump(kTokenStepDuration);
        _expectRing(
          tester,
          seat: 0,
          token: 0,
          because:
              'second leg\'s third and last step has landed on progress 7: '
              'the combined queued travel has truly ended',
        );
      },
    );
  });

  group('Case 6 (decision 3): a token already on the landing square waits '
      'for the mover', () {
    testWidgets(
      'seat 1 token 2 already sits on the absolute square seat 0 token 0 '
      'is moving onto (progress 3 -> 5, no capture, seat 1 unchanged): the '
      'opponent keeps its own layout mid-travel, both share the layout '
      'only once the mover lands',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        // Seat 0 progress 5 and seat 1 progress 44 are the same absolute
        // track square (entry 0 + 5 == entry 13 + 44 mod 52), the same
        // identity test/token_travel_test.dart's capture fixture uses;
        // here seat 1's token never changes, so there is no capture.
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, 44, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(hostKey: hostKey, tokens: before, mySeat: 0),
        );
        await tester.pump();

        final Offset fanCenter = _expectedFanCenter(
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          mySeat: 0,
        );
        _expectCenterNear(
          tester,
          key: const Key('token-1-2'),
          expected: fanCenter,
          because: 'before any move, seat 1 token 2 is the only occupant',
        );

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[-1, -1, 44, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectCenterNear(
          tester,
          key: const Key('token-1-2'),
          expected: fanCenter,
          because:
              'right after the rebuild, truth already has seat 0 token 0 '
              'on seat 1 token 2\'s square, but the mover has not landed',
        );

        await tester.pump(kTokenStepDuration);
        _expectCenterNear(
          tester,
          key: const Key('token-1-2'),
          expected: fanCenter,
          because:
              'the mover\'s first step (drawn progress 4): still not '
              'landed, seat 1 token 2 must keep its own layout',
        );

        await tester.pump(kTokenStepDuration);
        final Offset sharedOpponent = _expectedSharedCenter(
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          slot: 0,
          mySeat: 0,
        );
        final Offset sharedMover = _expectedSharedCenter(
          seat: 0,
          tokenIndex: 0,
          progress: 5,
          slot: 1,
          mySeat: 0,
        );
        _expectCenterNear(
          tester,
          key: const Key('token-1-2'),
          expected: sharedOpponent,
          because:
              'the mover\'s last step has landed on progress 5: both '
              'tokens now take the shared layout',
        );
        _expectCenterNear(
          tester,
          key: const Key('token-0-0'),
          expected: sharedMover,
          because:
              'the mover itself, once landed, also takes the shared '
              'layout slot its own occupant rank gives it',
        );
      },
    );
  });

  group('Case 7 (decision 4, unchanged)', () {
    testWidgets(
      'a legal token at rest, no travel involved, still has its ring',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> tokens = <int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: tokens,
            mySeat: 0,
            legal: const <int>{0},
          ),
        );
        await tester.pump();
        _expectRing(
          tester,
          seat: 0,
          token: 0,
          because: 'a legal token sitting still, mounted with no later rebuild',
        );
      },
    );

    testWidgets(
      'a snap (two seats each move a token in the same rebuild) draws the '
      'ring on the first frame, because nothing travels',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[5, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
          ),
        );
        await tester.pump();

        // Two seats each moving in the same rebuild is not a single-mover
        // move (contract C-252 rule 2), so board.dart must snap rather
        // than travel: the override is never set, so there is no
        // mid-travel window to even be mid of.
        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[8, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        _expectRing(
          tester,
          seat: 0,
          token: 0,
          because:
              'a snap draws straight at truth with no travel, so the ring '
              'must already be present on the very first frame after it',
        );
      },
    );

    testWidgets(
      'a token not in legal never shows a ring, at rest or travelling',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{},
          ),
        );
        await tester.pump();
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'token 0 is not in legal, at rest',
        );

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[6, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          _expectNoRing(
            tester,
            seat: 0,
            token: 0,
            because: 'token 0 is not in legal, step $i of its travel',
          );
          await tester.pump(kTokenStepDuration);
        }
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'token 0 is not in legal, after it has landed',
        );
      },
    );

    testWidgets(
      'board-token-hit-0-0 stays at the truth cell mid-travel, unaffected '
      'by the ring\'s own gating',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[6, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        final Offset expectedHit = _expectedFanCenter(
          seat: 0,
          tokenIndex: 0,
          progress: 6,
          mySeat: 0,
        );
        _expectCenterNear(
          tester,
          key: const Key('board-token-hit-0-0'),
          expected: expectedHit,
          because:
              'right after the rebuild, the hit target must already read '
              'truth (progress 6) while the drawn disc is still on 2',
        );
      },
    );

    testWidgets('a non-moving legal token keeps its ring throughout another '
        'token\'s travel (the realistic wrong fix: hiding every ring while '
        'anything travels)', (tester) async {
      final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
      final Map<int, List<int>> before = <int, List<int>>{
        0: <int>[2, -1, 10, -1],
        1: <int>[-1, -1, -1, -1],
        2: <int>[-1, -1, -1, -1],
        3: <int>[-1, -1, -1, -1],
      };
      await tester.pumpWidget(
        _harness(
          hostKey: hostKey,
          tokens: before,
          mySeat: 0,
          legal: const <int>{0, 2},
        ),
      );
      await tester.pump();
      _expectRing(
        tester,
        seat: 0,
        token: 2,
        because: 'token 2 is legal and at rest, before token 0 moves at all',
      );

      hostKey.currentState!.setTokens(<int, List<int>>{
        0: <int>[6, -1, 10, -1],
        1: <int>[-1, -1, -1, -1],
        2: <int>[-1, -1, -1, -1],
        3: <int>[-1, -1, -1, -1],
      });
      await tester.pump();
      _expectRing(
        tester,
        seat: 0,
        token: 2,
        because: 'right after token 0 starts moving, token 2 has not moved',
      );

      for (var i = 0; i < 4; i++) {
        await tester.pump(kTokenStepDuration);
        _expectRing(
          tester,
          seat: 0,
          token: 2,
          because:
              'token 0\'s travel step ${i + 1} of 4: token 2 never '
              'moved and must keep its ring throughout',
        );
      }
    });
  });

  group('Case 8 (decision 4, reduced motion): case 1\'s rule under '
      'kTokenStepDurationReduced', () {
    testWidgets(
      'with disableAnimations true, token 0 of seat 0 moving progress 2 '
      '-> 6 still carries no ring mid-travel, and the ring is present '
      'once it lands',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
            disableAnimations: true,
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[6, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'reduced motion, right after the rebuild, before any step',
        );

        for (final int step in <int>[1, 2, 3]) {
          await tester.pump(kTokenStepDurationReduced);
          _expectNoRing(
            tester,
            seat: 0,
            token: 0,
            because: 'reduced motion, step $step of 4, not yet at truth',
          );
        }

        await tester.pump(kTokenStepDurationReduced);
        _expectRing(
          tester,
          seat: 0,
          token: 0,
          because: 'reduced motion, the fourth and last step has landed',
        );
      },
    );
  });

  group('Case 9 (Arabic / RTL): cases 1 and 4 under Locale(ar)', () {
    testWidgets(
      'under Locale("ar"), token 0 of seat 0 moving progress 2 -> 6 still '
      'carries no ring mid-travel',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();
        expect(
          Directionality.of(tester.element(find.byType(LudoBoard))),
          TextDirection.rtl,
          reason:
              'fixture is broken: Locale("ar") must give an rtl ambient '
              'directionality',
        );

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[6, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectNoRing(
          tester,
          seat: 0,
          token: 0,
          because: 'ar/rtl, right after the rebuild, before any step',
        );

        for (final int step in <int>[1, 2, 3]) {
          await tester.pump(kTokenStepDuration);
          _expectNoRing(
            tester,
            seat: 0,
            token: 0,
            because: 'ar/rtl, step $step of 4, not yet at truth',
          );
        }
      },
    );

    testWidgets(
      'under Locale("ar"), after the last step the ring is present and '
      'centred on the disc',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[2, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            mySeat: 0,
            legal: const <int>{0},
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[6, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await tester.pump(kTokenStepDuration);
        }

        _expectRing(
          tester,
          seat: 0,
          token: 0,
          because: 'ar/rtl, the fourth and last step has landed on progress 6',
        );
        final Offset ringCenter = tester.getCenter(
          find.byKey(const Key('board-legal-ring-0-0')),
        );
        final Offset tokenCenter = tester.getCenter(
          find.byKey(const Key('token-0-0')),
        );
        final double distance = (ringCenter - tokenCenter).distance;
        expect(
          distance <= 0.5,
          isTrue,
          reason:
              'ar/rtl: ring centre $ringCenter must match the drawn disc '
              'centre $tokenCenter within 0.5px, distance '
              '${distance.toStringAsFixed(3)}px',
        );
      },
    );
  });
}
