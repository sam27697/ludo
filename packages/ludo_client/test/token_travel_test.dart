// Acceptance tests for work/ludo/orders/C-252-token-travel.md, written from
// that contract's text alone. Order 252 (lib/src/board.dart) is being built
// in parallel by a different worker; this file was not written against its
// content, and LudoBoard.onTokenStep, kTokenStepDuration,
// kTokenStepDurationReduced, kCaptureFlightDuration and
// kCaptureFlightDurationReduced do not exist on this branch's base. Every
// test below is expected to fail to compile there; see this order's own
// report for the exact dart analyze output.
//
// Mounting follows test/board_test.dart's bare-LudoBoard harness and
// test/board_seat_identity_test.dart's MaterialApp-with-localization-
// delegates technique, copied rather than imported. Each case gets its own
// mount: a small host StatefulWidget (_Host) holds the tokens map and
// exposes a setTokens(...) hook through a GlobalKey, so a case can rebuild
// the same LudoBoard element with new tokens the way a screen would.
//
// Every mount passes legal: const <int>{}. A non-empty legal set draws a
// ring that pulses forever (board.dart's _PulsingRing repeats under its own
// AnimationController), and pumpAndSettle against that never completes;
// none of the cases below call pumpAndSettle at all, for the same reason --
// every check is a specific tester.pump(duration) against a known clock,
// per this order's "pump one frame first, then the step durations".
//
// A board's drawn-token centre is read back from find.byKey(Key(
// 'token-S-T')) and compared with _expectedCenter below, which mirrors
// board.dart's own _tokenLayer math today (cellFor's cell, plus the same
// cellSize * 0.12 fan offset by token index, sign by token index) rather
// than inventing a second formula that could silently disagree with the
// widget under test. Tolerance is 0.5 logical pixels, this order's named
// slack.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';

const List<int> _seats = <int>[0, 1, 2, 3];
const double _boardSide = 400;
const double _cellSize = _boardSide / 15;

/// All four seats, each with four tokens sitting in their own yard
/// (progress -1). The default fixture for a case that only cares about one
/// seat's own tokens.
Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in _seats) seat: <int>[-1, -1, -1, -1],
};

/// The centre board.dart's `_tokenLayer` draws token [tokenIndex] of [seat]
/// at, when it sits still at [progress]: `cellFor`'s cell centre plus the
/// fan offset `_tokenLayer` applies today by token index (`cellSize * 0.12`,
/// negated for an even index on one axis, negated again for index < 2 on
/// the other) -- the same arithmetic `_tokenHitRect` uses for a hit target's
/// centre, which is why this one function covers both.
Offset _expectedCenter({
  required int seat,
  required int tokenIndex,
  required int progress,
}) {
  final BoardCell cell = cellFor(
    seat: seat,
    progress: progress,
    tokenIndex: tokenIndex,
  );
  final double fan = _cellSize * 0.12;
  final double fanDx = tokenIndex.isEven ? -fan : fan;
  final double fanDy = tokenIndex < 2 ? -fan : fan;
  return Offset(
    cell.col * _cellSize + _cellSize / 2 + fanDx,
    cell.row * _cellSize + _cellSize / 2 + fanDy,
  );
}

/// The board's top-left corner in the test window. [_expectedCenter] is in
/// board coordinates; the board sits centred in the window, so every
/// measured position is taken relative to this before comparing.
Offset _boardOrigin(WidgetTester tester) =>
    tester.getTopLeft(find.byType(LudoBoard));

/// Asserts the drawn token-[seat]-[tokenIndex] widget is centred on
/// [progress]'s cell (fan included), within 0.5px. [because] names the
/// moment being checked in the sequence, folded into the failure reason so
/// a mismatch says what was expected, what the actual centre was, and when.
void _expectDrawnAt(
  WidgetTester tester, {
  required int seat,
  required int tokenIndex,
  required int progress,
  required String because,
}) {
  final Offset actual =
      tester.getCenter(find.byKey(Key('token-$seat-$tokenIndex'))) -
      _boardOrigin(tester);
  final Offset expected = _expectedCenter(
    seat: seat,
    tokenIndex: tokenIndex,
    progress: progress,
  );
  final double distance = (actual - expected).distance;
  expect(
    distance <= 0.5,
    isTrue,
    reason:
        '$because: token-$seat-$tokenIndex should be centred on the cell '
        'of progress $progress ($expected), actual centre is $actual, '
        'distance ${distance.toStringAsFixed(3)}px (seed: seat=$seat, '
        'tokenIndex=$tokenIndex, progress=$progress)',
  );
}

/// Holds one [LudoBoard]'s `tokens` across rebuilds so a case can call
/// setTokens(...) through a GlobalKey the way a screen would hand the board
/// a fresh server snapshot, without a StatefulBuilder closure per case.
class _Host extends StatefulWidget {
  const _Host({super.key, required this.tokens, this.mySeat, this.onTokenStep});

  final Map<int, List<int>> tokens;
  final int? mySeat;
  final void Function(int seat, int token)? onTokenStep;

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
      legal: const <int>{},
      onTokenStep: widget.onTokenStep,
    );
  }
}

/// Mounts [_Host] under a MaterialApp with the app's own localization
/// delegates (needed only when [mySeat] is set, since board.dart's
/// Semantics hit target for "my" tokens reads AppLocalizations), inside a
/// fixed [_boardSide] square box, the same harness shape test/board_test.dart
/// and test/board_seat_identity_test.dart use.
Widget _harness({
  required GlobalKey<_HostState> hostKey,
  required Map<int, List<int>> tokens,
  int? mySeat,
  void Function(int seat, int token)? onTokenStep,
  bool disableAnimations = false,
}) {
  final Widget host = _Host(
    key: hostKey,
    tokens: tokens,
    mySeat: mySeat,
    onTokenStep: onTokenStep,
  );
  return MaterialApp(
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
  group('Rule 2/3: a single move visits every square in order', () {
    // Kills: a board that keeps today's behaviour (draws at the new cell at
    // once), and a board that draws a straight line from the old cell to
    // the new one instead of stopping on every square in between -- the
    // track turns a corner between progress 5 and 7 here (BoardCell(5, 6)
    // to BoardCell(6, 4)), so a straight-line tween's position at each step
    // boundary would miss cells 4, 5 and 6 by more than a cell width, far
    // outside the 0.5px tolerance.
    testWidgets(
      'token 0 of seat 0 moves from progress 3 to 7: one frame after the '
      'rebuild it is still on the cell of 3, then on the cells of 4, 5, 6, '
      '7 in turn, one kTokenStepDuration apart, and nowhere else at any of '
      'those step boundaries',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 3,
          because: 'before any rebuild',
        );

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 3,
          because:
              'one frame after the rebuild (an animation that just '
              'started advances by zero)',
        );

        for (final int progress in <int>[4, 5, 6, 7]) {
          await tester.pump(kTokenStepDuration);
          _expectDrawnAt(
            tester,
            seat: 0,
            tokenIndex: 0,
            progress: progress,
            because:
                'kTokenStepDuration after the previous step boundary, '
                'expecting the step that lands on progress $progress',
          );
        }
      },
    );
  });

  group('Rule 2: leaving the yard', () {
    // Kills: a board that draws straight onto the track cell for a token
    // leaving the yard, skipping the "drawn in the yard" frame the
    // contract requires before the single step runs.
    testWidgets(
      'token 0 of seat 0 moves from the yard (-1) to progress 0: drawn in '
      'the yard right after the rebuild, then on the cell of progress 0 '
      'one kTokenStepDuration later',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = _allInYard();
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[0, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: -1,
          because:
              'one frame after leaving the yard, before the single step '
              'has run',
        );

        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 0,
          because: 'kTokenStepDuration after leaving the yard',
        );
      },
    );
  });

  group('Rule 1: truth is immediate', () {
    // Kills: a board that keeps the tap target, legal ring or Semantics
    // identifier pinned to the travelling token's visual position instead
    // of the latest `tokens` it was given -- the hit target and identifier
    // must already read progress 7 while the drawn token is still shown on
    // progress 3's cell.
    testWidgets(
      'right after a rebuild moves token 0 of seat 0 from progress 3 to 7, '
      'board-token-hit-0-0 and the Semantics identifier of token-0-0 '
      'already read the cell of 7, while the drawn token is still on the '
      'cell of 3',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(hostKey: hostKey, tokens: before, mySeat: 0),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        final BoardCell expectedCell = cellFor(
          seat: 0,
          progress: 7,
          tokenIndex: 0,
        );
        final String expectedId =
            'cell-${expectedCell.col}-'
            '${expectedCell.row}';

        final Rect hitRect = tester.getRect(
          find.byKey(const Key('board-token-hit-0-0')),
        );
        final Offset expectedHitCenter = _expectedCenter(
          seat: 0,
          tokenIndex: 0,
          progress: 7,
        );
        final double hitDistance =
            (hitRect.center - _boardOrigin(tester) - expectedHitCenter)
                .distance;
        expect(
          hitDistance <= 0.5,
          isTrue,
          reason:
              'board-token-hit-0-0 should already be centred on progress '
              "7's cell ($expectedHitCenter) right after the rebuild, "
              'actual centre is ${hitRect.center}, distance '
              '${hitDistance.toStringAsFixed(3)}px',
        );

        expect(
          find.descendant(
            of: find.byKey(const Key('token-0-0')),
            matching: find.bySemanticsIdentifier(expectedId),
            matchRoot: true,
          ),
          findsOneWidget,
          reason:
              'token-0-0 should carry Semantics(identifier: "$expectedId") '
              'right after the rebuild, following progress 7, even though '
              'the drawn token has not visually arrived there yet',
        );

        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 3,
          because:
              'the drawn token itself must still be travelling: only the '
              'tap target and the Semantics identifier jump immediately',
        );

        handle.dispose();
      },
    );
  });

  group('Rule 4: a capture', () {
    // Kills: a board that flies the captured token home at once (the
    // instant the move is recognised) instead of holding it on its old
    // square until the mover's own last step ends.
    testWidgets(
      'token 0 of seat 0 moves from progress 3 to 5, capturing token 2 of '
      'seat 1 on that square: the captured token stays on its old square '
      "through both of the mover's steps, then is drawn in its yard slot "
      'after kCaptureFlightDuration',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        // Seat 0 progress 5 and seat 1 progress 44 are the same absolute
        // track square (entry 0 + 5 == entry 13 + 44 mod 52), the same
        // identity test/board_test.dart's property 4 group exercises.
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, 44, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          because: 'before any rebuild',
        );

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          because: 'one frame after the rebuild that captures it',
        );

        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          because: "the mover's first step (to progress 4), not its last",
        );

        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 2,
          progress: 44,
          because:
              "the mover's last step has just ended; the capture flight "
              'has not had any time to run yet',
        );

        await tester.pump(kCaptureFlightDuration);
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 2,
          progress: -1,
          because: 'kCaptureFlightDuration after the mover arrived',
        );
      },
    );
  });

  group('Rule 2 (snap): anything other than a single clean move', () {
    // Kills: a board that tries to animate a change rule 2 explicitly
    // excludes from "what travels" -- these three sub-cases cover the
    // three ways a tokens change is not a move (not a single mover, more
    // than one mover with no capture, and a delta outside 1..6), each of
    // which must be drawn at once with no travel.
    testWidgets(
      'every token reset to -1 at once: drawn at the yard cells after one '
      'frame, with no travel',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, 0, 0, 0],
          1: <int>[5, 0, 0, 0],
          2: <int>[0, 0, 0, 0],
          3: <int>[0, 0, 0, 0],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(_allInYard());
        await tester.pump();

        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: -1,
          because: 'a full reset must snap to the yard at once',
        );
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 0,
          progress: -1,
          because: 'a full reset must snap to the yard at once',
        );
      },
    );

    testWidgets(
      'two seats each move a token in the same rebuild: both are drawn at '
      'their new cells after one frame, with no travel',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[5, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[8, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 5,
          because:
              'two seats moving in the same rebuild is not a single-mover '
              'move (rule 2), so this must snap rather than travel',
        );
        _expectDrawnAt(
          tester,
          seat: 1,
          tokenIndex: 0,
          progress: 8,
          because:
              'two seats moving in the same rebuild is not a single-mover '
              'move (rule 2), so this must snap rather than travel',
        );
      },
    );

    testWidgets(
      'a single token jumps by 7 (outside the 1..6 move range): drawn at '
      'the new cell after one frame, with no travel',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[0, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 7,
          because:
              'a delta of 7 is outside the 1..6 move range, so this must '
              'snap rather than travel',
        );
      },
    );
  });

  group('Rule 5: reduced motion shortens steps, never skips them', () {
    // Kills: reduced motion removing meaning (jumping straight to the end,
    // or skipping a square) instead of only shortening the motion -- the
    // same four checkpoints as the Rule 2/3 test, timed at
    // kTokenStepDurationReduced instead of kTokenStepDuration.
    testWidgets(
      'with disableAnimations true, token 0 of seat 0 moving from progress '
      '3 to 7 still visits the cells of 4, 5, 6, 7 in order, one '
      'kTokenStepDurationReduced apart',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(hostKey: hostKey, tokens: before, disableAnimations: true),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 3,
          because: 'one frame after the rebuild, reduced motion included',
        );

        for (final int progress in <int>[4, 5, 6, 7]) {
          await tester.pump(kTokenStepDurationReduced);
          _expectDrawnAt(
            tester,
            seat: 0,
            tokenIndex: 0,
            progress: progress,
            because:
                'kTokenStepDurationReduced after the previous step '
                'boundary, expecting the step that lands on progress '
                '$progress',
          );
        }
      },
    );
  });

  group('Rule 6: a move that arrives while another plays waits for it', () {
    // Kills: a second move starting before the first one has arrived --
    // the realistic wrong implementation this bullet names. Two distinct
    // tokens of seat 0: token 0 travels progress 3 to 7, then while it is
    // mid-travel token 1 is told to move from progress 10 to 12. Token 1
    // must not leave its square until token 0 has arrived, and token 0's
    // own remaining steps must run at half duration while token 1 waits.
    testWidgets(
      'token 1 does not leave progress 10 until token 0 has arrived at '
      "progress 7; token 0's remaining steps run at half duration once "
      'token 1 is queued behind it',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, 10, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, 10, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 3,
          because: 'one frame after token 0 starts moving',
        );

        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 4,
          because:
              "token 0's first step, at full duration (nothing queued "
              'behind it yet)',
        );

        // Token 1's move is told to the board while token 0 still has
        // three remaining steps (to progress 5, 6, 7).
        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, 12, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 10,
          because: 'one frame after being queued, token 1 has not moved',
        );
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 4,
          because:
              'one frame after token 1 is queued, token 0 has not yet '
              'taken its next (now half-duration) step',
        );

        final Duration halfStep = kTokenStepDuration ~/ 2;

        await tester.pump(halfStep);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 5,
          because:
              "token 0's next step runs at half duration while token 1 "
              'waits behind it',
        );
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 10,
          because: "token 1 must not leave its square before token 0 arrives",
        );

        await tester.pump(halfStep);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 6,
          because: 'another half-duration step for token 0',
        );
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 10,
          because: "token 1 must not leave its square before token 0 arrives",
        );

        await tester.pump(halfStep);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 0,
          progress: 7,
          because: "token 0's last (half-duration) step: it has now arrived",
        );
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 10,
          because:
              'at the exact moment token 0 arrives, token 1 has still not '
              'taken a step of its own',
        );

        // Token 0 has arrived and nothing else is queued, so token 1 now
        // runs at full duration.
        await tester.pump();
        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 11,
          because:
              "token 1's own first step, at full duration, now that "
              "token 0's move is finished and nothing else is queued",
        );

        await tester.pump(kTokenStepDuration);
        _expectDrawnAt(
          tester,
          seat: 0,
          tokenIndex: 1,
          progress: 12,
          because: "token 1's last step",
        );
      },
    );
  });

  group('Rule 7: onTokenStep', () {
    // Kills: onTokenStep never firing, firing for the wrong token, firing
    // out of order, firing more or fewer than once per square travelled,
    // or firing for the captured token's flight home.
    testWidgets(
      'onTokenStep fires exactly 4 times, each (0, 0), in order, for a '
      'move from progress 3 to 7 that also captures a token, and never '
      'fires for the captured token',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final List<(int, int)> calls = <(int, int)>[];
        // Seat 1 token 2 at progress 46 sits on the same absolute square
        // (7) that seat 0 token 0 arrives on at progress 7.
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, 46, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _harness(
            hostKey: hostKey,
            tokens: before,
            onTokenStep: (int seat, int token) => calls.add((seat, token)),
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        expect(
          calls,
          isEmpty,
          reason:
              'no step has completed yet, one frame after the rebuild; '
              'got $calls',
        );

        for (var i = 0; i < 4; i++) {
          await tester.pump(kTokenStepDuration);
        }
        // Let the capture flight finish too, so a callback wrongly wired
        // to the capture flight would show up here as well.
        await tester.pump(kCaptureFlightDuration);

        expect(
          calls,
          <(int, int)>[(0, 0), (0, 0), (0, 0), (0, 0)],
          reason:
              'expected exactly 4 onTokenStep calls, each (seat 0, token '
              '0), one per square travelled from progress 3 to 7, and none '
              'for the captured seat 1 token 2; got $calls',
        );
      },
    );
  });

  group('Rule 8: lifecycle', () {
    // Kills: a ticker or timer started even for a board that is mounted
    // once and never updated.
    testWidgets(
      'a board built once and never updated runs no animation and holds '
      'no pending timer',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        await tester.pumpWidget(
          _harness(hostKey: hostKey, tokens: _allInYard()),
        );
        await tester.pump();

        expect(
          SchedulerBinding.instance.transientCallbackCount,
          0,
          reason:
              'a board that was never updated must not have a ticker or '
              'animation scheduled',
        );
        // A leftover dart:async Timer would independently fail this test
        // at teardown, since flutter_test's binding refuses to complete a
        // test that still has a pending Timer.
      },
    );

    // Kills: a ticker or timer left running (or an exception thrown) when
    // the board is torn down while a move is still travelling.
    testWidgets(
      'disposing the board mid-travel stops every ticker or timer the '
      'travel used, with no exception',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(_harness(hostKey: hostKey, tokens: before));
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        await tester.pump(kTokenStepDuration);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: 'disposing the board mid-travel must not throw',
        );
        // A leftover dart:async Timer or scheduled ticker would
        // independently fail this test at teardown.
      },
    );
  });
}
