// Acceptance tests for work/ludo/orders/C-331-seat-marks.md, written from
// that contract's text alone (and order 332's own goal list) against no
// implementation of it: order 331 (lib/src/seat_mark.dart, plus the sites
// it threads the mark into -- lib/src/board.dart, lib/src/seat_card.dart,
// lib/src/die_mark.dart) is being built in parallel by a different worker
// on this same base, origin/main c3f53bd; this file never touches lib/.
// SeatMark, SeatShape, seatShapeOf and seatMarkInkOf do not exist on this
// branch's base commit, so every test below is expected to fail to compile
// there -- see this order's own report for the exact command and output.
//
// Mounting copies, rather than imports, three existing harnesses so this
// file never depends on a second worker's private helpers:
//   - test/board_test.dart's bare-LudoBoard-in-a-fixed-SizedBox harness, for
//     the static (non-travelling) token-mark checks;
//   - test/token_travel_test.dart's `_Host` GlobalKey-driven rebuild harness
//     (renamed `_TravelHost` here), for the mid-travel check -- a case must
//     rebuild the same LudoBoard element with new `tokens` to make it play a
//     step at all;
//   - test/board_safe_squares_test.dart's MaterialApp-with-localization-
//     delegates-plus-mySeat harness, for the one tap/legal-ring case rule 5
//     asks this file to re-run unchanged.
// test/seat_card_names_test.dart's and test/board_seat_identity_test.dart's
// own fixtures (a bare SeatState record, and Locale('ar') plus Directionality
// read off the mounted element) are the model for the SeatCard and
// board-seat-name-chip cases.
//
// Ambiguities found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   1. Rule 3's SeatPipStrip default pip size (`kSeatPipSize` = 8, die_mark.
//      dart) gives a 50%-of-diameter mark of size 4, which is itself below
//      rule 4's 6px floor -- so an ordinary (non-turn) pip's mark is
//      expected to exist in the tree (found by find.byType(SeatMark)) but
//      to paint nothing at that real size. The turn pip (pipSize * 1.5 = 12)
//      gives a mark of exactly 6, which is *not* below the floor ("below 6"
//      reads as strictly less than 6) and so is expected to paint. This
//      file does not assert paint behaviour for either pip size -- only
//      presence, seat and the turn pip's mark being drawn larger than an
//      ordinary one -- since order 332's own goal item 4 asks only for
//      presence and relative size at this site, not a paint check; the
//      apparent tension between contract rule 3 ("every pip ... carries the
//      mark") and rule 4 ("below 6 ... not drawn") is exactly contract rule
//      4's own parenthetical ("a pip at a tiny size would only be noise")
//      describing this precise case, not a contradiction, and is reported
//      here only because resolving it required going outside order 332's
//      own goal list.
//   2. Contract rule 1 reads "a rect or path for 2" rather than one fixed
//      canvas call, said verbatim in order 332's own goal item 2 too; the
//      seat-2 paint check below accepts either with `anyOf`, rather than
//      the goal item 1 test (which proves the shape mapping itself as a
//      logical fact via seatShapeOf, so no canvas-call ambiguity reaches
//      that test).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/net/snapshot.dart' show SeatState;
import 'package:ludo_client/src/seat_card.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart';

const List<int> _seats = <int>[0, 1, 2, 3];
const double _boardSide = 400;

/// All four seats, each with four tokens -- one in the yard (-1), one on
/// the main track, one in the home column and one finished -- so a single
/// mount gives every `token-$seat-$i` key a state goal item 3 names (yard,
/// track, home column) plus the finished state contract rule 2 also lists.
Map<int, List<int>> _tokensInEveryState() => <int, List<int>>{
  for (final int seat in _seats) seat: <int>[-1, 15, 53, 57],
};

/// test/board_test.dart's own bare-LudoBoard harness, copied: no
/// localization delegates, since `mySeat` stays null here and board.dart
/// only reads AppLocalizations for a seat's own tap target.
Widget _staticBoardHarness({required Map<int, List<int>> tokens}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _boardSide,
          height: _boardSide,
          child: LudoBoard(tokens: tokens, seatsInPlay: _seats),
        ),
      ),
    ),
  );
}

/// test/board_safe_squares_test.dart's own harness, copied: full
/// localization delegates, since this is the one case in this file that
/// sets `mySeat` and taps a hit target, which reads AppLocalizations.
Widget _tapHarness({
  required Map<int, List<int>> tokens,
  required int mySeat,
  required Set<int> legal,
  void Function(int token)? onTokenTap,
  void Function(int token)? onIllegalTokenTap,
}) {
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
          child: LudoBoard(
            tokens: tokens,
            seatsInPlay: _seats,
            mySeat: mySeat,
            legal: legal,
            onTokenTap: onTokenTap,
            onIllegalTokenTap: onIllegalTokenTap,
          ),
        ),
      ),
    ),
  );
}

/// test/board_seat_identity_test.dart's own `_fixedHarness`, copied: full
/// localization delegates (needed for Locale('ar') to resolve a RTL
/// Directionality the same way the app itself resolves it) and a `locale`
/// parameter, for the board-seat-name-chip cases.
Widget _chipHarness({
  required Map<int, List<int>> tokens,
  required Map<int, String> seatNames,
  Locale locale = const Locale('en'),
}) {
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
          child: LudoBoard(
            tokens: tokens,
            seatsInPlay: _seats,
            seatNames: seatNames,
          ),
        ),
      ),
    ),
  );
}

/// test/token_travel_test.dart's own `_Host`, copied under a new private
/// name (so a future merge of both files cannot collide on `_Host`): holds
/// one LudoBoard's `tokens` across rebuilds so a case can call
/// `setTokens(...)` through a GlobalKey the way a screen hands the board a
/// fresh server snapshot.
class _TravelHost extends StatefulWidget {
  const _TravelHost({super.key, required this.tokens});

  final Map<int, List<int>> tokens;

  @override
  State<_TravelHost> createState() => _TravelHostState();
}

class _TravelHostState extends State<_TravelHost> {
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
      legal: const <int>{},
    );
  }
}

Widget _travelHarness({
  required GlobalKey<_TravelHostState> hostKey,
  required Map<int, List<int>> tokens,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _boardSide,
          height: _boardSide,
          child: _TravelHost(key: hostKey, tokens: tokens),
        ),
      ),
    ),
  );
}

void main() {
  // ===========================================================================
  // Rule 1 -- one shape per seat, fixed forever; the contrasting ink.
  // ===========================================================================
  group('Rule 1: seatShapeOf and seatMarkInkOf', () {
    test('seatShapeOf maps seat 0 to circle, 1 to triangle, 2 to square, 3 to '
        'diamond', () {
      // Kills: seats 1 and 3 given the same shape (the two non-circle,
      // non-ink-coloured seats, the easiest pair to confuse), or any
      // other permutation of the four shapes across the four seats.
      const List<SeatShape> expected = <SeatShape>[
        SeatShape.circle,
        SeatShape.triangle,
        SeatShape.square,
        SeatShape.diamond,
      ];
      for (final int seat in _seats) {
        expect(
          seatShapeOf(seat),
          expected[seat],
          reason:
              'seatShapeOf($seat) must be ${expected[seat]}; got '
              '${seatShapeOf(seat)} (seed: seat=$seat)',
        );
      }
    });

    test('seatMarkInkOf(2) is LudoColors.ink; seats 0, 1 and 3 are white '
        '0xFFFFFFFF', () {
      // Kills: the ink/white pick swapped (ink painted on a dark seat,
      // where it would not contrast, or white kept on seat 2's yellow,
      // where it would not contrast either).
      expect(
        seatMarkInkOf(2),
        LudoColors.ink,
        reason:
            'seatMarkInkOf(2) must be LudoColors.ink (seat 2 is yellow, '
            '${LudoColors.seats[2]}); got ${seatMarkInkOf(2)}',
      );
      for (final int seat in <int>[0, 1, 3]) {
        expect(
          seatMarkInkOf(seat),
          const Color(0xFFFFFFFF),
          reason:
              'seatMarkInkOf($seat) must be white (0xFFFFFFFF); got '
              '${seatMarkInkOf(seat)} (seed: seat=$seat)',
        );
      }
    });
  });

  // ===========================================================================
  // Rule 1 / rule 4 -- SeatMark's own painting and semantics, in isolation.
  // ===========================================================================
  group('SeatMark painting (rule 1) and the size floor (rule 4)', () {
    // One mount per seat (standing lesson 35): each seat is a different
    // SeatMark instance, not a state change on one mounted widget.
    for (final int seat in _seats) {
      testWidgets(
        'at size 20, seat $seat paints in its own shape and ink colour',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(child: SeatMark(seat: seat, size: 20)),
              ),
            ),
          );
          await tester.pump();

          final Finder paint = find.byType(SeatMark);
          final Color ink = seatMarkInkOf(seat);

          // Kills: seat 0 drawn as anything other than a circle, seats 1
          // and 3 drawn as the wrong shape family (a rect/circle instead of
          // a path), seat 2 drawn in a colour other than its own
          // seatMarkInkOf (the single clearest way a shape-and-colour
          // painter can silently regress one seat without breaking any of
          // the other three).
          if (seat == 0) {
            expect(
              paint,
              paints..circle(color: ink),
              reason:
                  'seat 0 (circle) must paint a circle in $ink at size 20; '
                  'seed: seat=0',
            );
          } else if (seat == 2) {
            expect(
              paint,
              anyOf(paints..rect(color: ink), paints..path(color: ink)),
              reason:
                  'seat 2 (square) must paint a rect or a path in $ink at '
                  'size 20; seed: seat=2',
            );
          } else if (seat == 1) {
            expect(
              paint,
              paints..path(color: ink),
              reason:
                  'seat 1 (triangle) must paint a path in $ink at size 20; '
                  'seed: seat=1',
            );
          } else {
            // A diamond is either a path or a square drawn on a canvas
            // rotated 45 degrees. Kills: seat 3 drawn as the unrotated
            // square of seat 2.
            expect(
              paint,
              anyOf(
                paints..path(color: ink),
                paints
                  ..rotate(angle: math.pi / 4)
                  ..rect(color: ink),
              ),
              reason:
                  'seat 3 (diamond) must paint a path, or a rect on a canvas '
                  'rotated by pi/4, in $ink at size 20; seed: seat=3',
            );
          }
        },
      );
    }

    testWidgets('size 5 (below the 6px floor) paints nothing', (tester) async {
      // Kills: the floor check missing entirely, or checking the wrong
      // property (e.g. the seat instead of the size).
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: SeatMark(seat: 0, size: 5))),
        ),
      );
      await tester.pump();

      expect(
        find.byType(SeatMark),
        paintsNothing,
        reason: 'SeatMark(seat: 0, size: 5) must paint nothing; seed: size=5',
      );
    });

    // Additional boundary coverage beyond order 332's own named case (size
    // 5): rule 4's own wording is "below 6", i.e. strictly less than 6, so
    // exactly 6 must still paint. Kills an off-by-one floor (size <= 6
    // instead of size < 6).
    testWidgets('size 6 (exactly at the floor) still paints something', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: SeatMark(seat: 0, size: 6))),
        ),
      );
      await tester.pump();

      expect(
        find.byType(SeatMark),
        isNot(paintsNothing),
        reason:
            'SeatMark(seat: 0, size: 6) must still paint (6 is not "below '
            '6"); seed: size=6',
      );
    });

    testWidgets(
      'SeatMark contributes no semantics node of its own (ExcludeSemantics)',
      (tester) async {
        // Kills: ExcludeSemantics dropped (or replaced with a plain
        // wrapper), which would let the shape leak a second, redundant
        // accessibility signal the existing Semantics label did not ask
        // for.
        final SemanticsHandle handle = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Semantics(
                  key: const Key('seat-mark-probe'),
                  label: 'probe',
                  child: const SeatMark(seat: 1, size: 20),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final SemanticsNode probe = tester.getSemantics(
          find.byKey(const Key('seat-mark-probe')),
        );
        expect(
          probe.childrenCount,
          0,
          reason:
              'the "probe" Semantics node must have no children once '
              'SeatMark is wrapped in ExcludeSemantics; got '
              '${probe.childrenCount} (seed: seat=1, size=20)',
        );
        expect(
          find.bySemanticsLabel(RegExp('circle|triangle|square|diamond')),
          findsNothing,
          reason:
              'no new semantics label naming a shape must appear under '
              'SeatMark',
        );
        // childrenCount alone also reads 0 without ExcludeSemantics, since an
        // unlabelled child merges into its parent. Kills: the wrapper removed.
        expect(
          find.descendant(
            of: find.byType(SeatMark),
            matching: find.byType(ExcludeSemantics),
          ),
          findsOneWidget,
        );
        handle.dispose();
      },
    );
  });

  // ===========================================================================
  // Rule 2 -- every token carries its seat's mark, centred, at 50% of the
  // drawn token diameter, in every state.
  // ===========================================================================
  group('Rule 2: every token carries its seat mark at 50% of its diameter', () {
    testWidgets(
      'all four seats, each with a token in the yard, on the track, in the '
      r'home column and finished: each token-$seat-$i has exactly one '
      'SeatMark of that seat at 50% of the token diameter',
      (tester) async {
        await tester.pumpWidget(
          _staticBoardHarness(tokens: _tokensInEveryState()),
        );
        await tester.pump();

        for (final int seat in _seats) {
          for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
            final Finder tokenFinder = find.byKey(
              Key('token-$seat-$tokenIndex'),
            );
            final Finder markFinder = find.descendant(
              of: tokenFinder,
              matching: find.byType(SeatMark),
            );

            // Kills: the mark drawn only for some states (e.g. only on the
            // main track, not the yard/home-column/finished tokens this
            // fixture also covers).
            expect(
              markFinder,
              findsOneWidget,
              reason:
                  'token-$seat-$tokenIndex must have exactly one SeatMark '
                  'descendant (seed: seat=$seat, token=$tokenIndex, '
                  'progress=${_tokensInEveryState()[seat]![tokenIndex]})',
            );

            final SeatMark mark = tester.widget<SeatMark>(markFinder);
            // Kills: every token drawing seat 0's mark regardless of its
            // own seat (the mark wired to a constant instead of this
            // token's seat).
            expect(
              mark.seat,
              seat,
              reason:
                  'the SeatMark under token-$seat-$tokenIndex must have '
                  '.seat == $seat; got ${mark.seat} (seed: seat=$seat, '
                  'token=$tokenIndex)',
            );

            final double tokenDiameter = tester.getSize(tokenFinder).width;
            final double markDiameter = tester.getSize(markFinder).width;
            // Kills: the mark given a fixed size regardless of the token's
            // own drawn diameter, or a size fraction other than 50%
            // (e.g. 100% of the disc, which would draw outside it).
            expect(
              (markDiameter - tokenDiameter / 2).abs() <= 1.0,
              isTrue,
              reason:
                  'token-$seat-$tokenIndex is drawn at diameter '
                  '$tokenDiameter; its SeatMark must be $tokenDiameter / 2 '
                  '= ${tokenDiameter / 2} within 1 logical px, got '
                  '$markDiameter (seed: seat=$seat, token=$tokenIndex)',
            );
          }
        }
      },
    );

    testWidgets(
      'a token mid-travel (one kTokenStepDuration into a multi-step move) '
      'still has its SeatMark',
      (tester) async {
        // Kills: the mark attached only to the token's resting Positioned
        // (drawn straight from truth) and dropped for the travelling
        // Positioned board.dart builds mid-step -- board.dart's own
        // `_tokenLayer` keeps the ring, the hit target and the Semantics
        // identifier correct mid-travel (contract C-252 rule 1); this case
        // is the same question asked of the mark.
        final GlobalKey<_TravelHostState> hostKey =
            GlobalKey<_TravelHostState>();
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _travelHarness(hostKey: hostKey, tokens: before),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[7, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        await tester.pump(kTokenStepDuration);
        // Now drawn on the cell of progress 4 (one step in), truth is 7:
        // still mid-travel, not yet landed.

        final Finder tokenFinder = find.byKey(const Key('token-0-0'));
        final Finder markFinder = find.descendant(
          of: tokenFinder,
          matching: find.byType(SeatMark),
        );
        expect(
          markFinder,
          findsOneWidget,
          reason:
              'token-0-0, one kTokenStepDuration into a 3-to-7 move, must '
              'still carry exactly one SeatMark; seed: seat=0, token=0, '
              'oldProgress=3, newProgress=7, elapsed=1 step',
        );
        expect(
          tester.widget<SeatMark>(markFinder).seat,
          0,
          reason:
              'the mid-travel SeatMark under token-0-0 must still be '
              'seat 0\'s mark',
        );
      },
    );
  });

  // ===========================================================================
  // Rule 3 -- every seat disc elsewhere carries the same mark, at 50% of
  // that disc's diameter: SeatCard, SeatPipStrip, the board seat-name chip.
  // ===========================================================================
  group('Rule 3: SeatCard, SeatPipStrip and the board seat-name chip', () {
    for (final int seat in _seats) {
      testWidgets(
        "SeatCard for seat $seat carries one SeatMark of seat $seat, at "
        "50% of the token disc's diameter",
        (tester) async {
          final SeatState state = SeatState(
            seat: seat,
            name: 'P$seat',
            connected: true,
            tokens: const <int>[-1, -1, -1, -1],
            clientSeed: null,
            seedOrigin: null,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SeatCard(
                    seat: state,
                    isMine: false,
                    isHost: false,
                    youLabel: 'You',
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final Finder discFinder = find.byKey(Key('lobby-seat-$seat-token'));
          final Finder markFinder = find.descendant(
            of: discFinder,
            matching: find.byType(SeatMark),
          );
          // Kills: the lobby seat card left undecorated by this contract
          // (the token disc still a plain coloured circle, no mark at all).
          expect(
            markFinder,
            findsOneWidget,
            reason:
                'lobby-seat-$seat-token must have exactly one SeatMark '
                'descendant (seed: seat=$seat)',
          );
          expect(
            tester.widget<SeatMark>(markFinder).seat,
            seat,
            reason: 'the SeatCard mark for seat $seat must have .seat == $seat',
          );

          final double discDiameter = tester.getSize(discFinder).width;
          final double markDiameter = tester.getSize(markFinder).width;
          // Kills: the mark given a size independent of kSpace6 (the
          // disc's own diameter), so a future resize of the disc would
          // silently desync the mark from it.
          expect(
            (markDiameter - discDiameter / 2).abs() <= 1.0,
            isTrue,
            reason:
                'lobby-seat-$seat-token is drawn at diameter $discDiameter '
                '(kSpace6 = $kSpace6); its SeatMark must be '
                '${discDiameter / 2} within 1 logical px, got $markDiameter '
                '(seed: seat=$seat)',
          );
        },
      );
    }

    testWidgets(
      'SeatPipStrip(turnSeat: 1) draws one SeatMark per pip, each of that '
      "pip's own seat, and the turn pip's mark (seat 1) larger than the "
      'others',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: SeatPipStrip(turnSeat: 1))),
          ),
        );
        await tester.pump();

        final Map<int, double> markSizes = <int, double>{};
        for (final int seat in _seats) {
          final Finder pipFinder = find.byKey(Key('game-seat-pip-$seat'));
          final Finder markFinder = find.descendant(
            of: pipFinder,
            matching: find.byType(SeatMark),
          );
          // Kills: a pip strip that keeps drawing plain coloured dots with
          // no mark at all (the pre-contract behaviour).
          expect(
            markFinder,
            findsOneWidget,
            reason:
                'game-seat-pip-$seat must have exactly one SeatMark '
                'descendant (seed: seat=$seat, turnSeat=1)',
          );
          expect(
            tester.widget<SeatMark>(markFinder).seat,
            seat,
            reason: 'the pip mark for seat $seat must have .seat == $seat',
          );
          markSizes[seat] = tester.getSize(markFinder).width;
        }

        for (final int other in <int>[0, 2, 3]) {
          // Kills: the turn pip enlarging its own coloured dot (already
          // true today) without also enlarging its mark, which would leave
          // the shape signal out of step with the size signal on the one
          // pip doctrine P9 most wants it on (the current turn).
          expect(
            markSizes[1]! > markSizes[other]!,
            isTrue,
            reason:
                "seat 1's pip mark (${markSizes[1]}) must be larger than "
                'seat $other\'s (${markSizes[other]}) when turnSeat is 1; '
                'seed: turnSeat=1, sizes=$markSizes',
          );
        }
      },
    );

    testWidgets(
      'en: board-seat-name-0 carries one SeatMark of seat 0, placed before '
      '(lower x than) the name text',
      (tester) async {
        await tester.pumpWidget(
          _chipHarness(
            tokens: _tokensInEveryState(),
            seatNames: const <int, String>{0: 'Sam'},
          ),
        );
        await tester.pump();

        final Finder chip = find.byKey(const Key('board-seat-name-0'));
        final Finder markFinder = find.descendant(
          of: chip,
          matching: find.byType(SeatMark),
        );
        expect(
          markFinder,
          findsOneWidget,
          reason:
              'board-seat-name-0 must have exactly one SeatMark descendant '
              '(seed: locale=en, seat=0)',
        );
        expect(tester.widget<SeatMark>(markFinder).seat, 0);

        final Finder nameText = find.descendant(
          of: chip,
          matching: find.text('Sam'),
        );
        expect(nameText, findsOneWidget);

        final double markX = tester.getCenter(markFinder).dx;
        final double nameX = tester.getCenter(nameText).dx;
        // Kills: the disc placed by a fixed `left:` (always on the
        // physical-left) rather than by `start:` -- in LTR this test alone
        // cannot distinguish the two, which is exactly why the Arabic case
        // below exists: a `left:`-placed disc would pass here and fail
        // there.
        expect(
          markX < nameX,
          isTrue,
          reason:
              "en: board-seat-name-0's mark (x=$markX) must sit before the "
              'name text (x=$nameX), i.e. at a lower x; seed: locale=en',
        );
      },
    );

    testWidgets(
      'ar: board-seat-name-0 carries one SeatMark of seat 0, placed after '
      '(higher x than) the name text -- mirrored by start, not left',
      (tester) async {
        await tester.pumpWidget(
          _chipHarness(
            tokens: _tokensInEveryState(),
            seatNames: const <int, String>{0: 'Sam'},
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();

        final Finder chip = find.byKey(const Key('board-seat-name-0'));
        final Finder markFinder = find.descendant(
          of: chip,
          matching: find.byType(SeatMark),
        );
        expect(
          markFinder,
          findsOneWidget,
          reason:
              'board-seat-name-0 must have exactly one SeatMark descendant '
              '(seed: locale=ar, seat=0)',
        );
        expect(tester.widget<SeatMark>(markFinder).seat, 0);

        final Finder nameText = find.descendant(
          of: chip,
          matching: find.text('Sam'),
        );
        expect(nameText, findsOneWidget);

        final double markX = tester.getCenter(markFinder).dx;
        final double nameX = tester.getCenter(nameText).dx;
        // Kills: the disc placed by `left:` instead of `start:` -- under
        // RTL that would keep the mark on the physical-left (lower x, same
        // as the en case above) instead of mirroring to the chip's visual
        // start, which under RTL is the physical-right (higher x).
        expect(
          markX > nameX,
          isTrue,
          reason:
              "ar: board-seat-name-0's mark (x=$markX) must sit after the "
              'name text (x=$nameX), i.e. at a higher x, because Arabic '
              "mirrors the chip's start edge to the physical right; seed: "
              'locale=ar',
        );
      },
    );
  });

  // ===========================================================================
  // Rule 5 -- nothing else moves: the tap and legal-ring behaviour the
  // board already had is unchanged by adding the mark.
  // ===========================================================================
  group('Rule 5: the tap and legal-ring behaviour is unchanged', () {
    testWidgets(
      'a tap on a legal token still reaches onTokenTap exactly once, and '
      'the legal ring is still drawn, with the seat mark present too',
      (tester) async {
        // Setup re-used from test/board_safe_squares_test.dart's "a tap on
        // a legal token sitting on a safe square still sends exactly one
        // move" case: seat 0 token 0, progress 5, mySeat 0, legal {0}.
        final List<int> tapped = <int>[];
        final List<int> shaken = <int>[];
        final Map<int, List<int>> tokens = <int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };

        await tester.pumpWidget(
          _tapHarness(
            tokens: tokens,
            mySeat: 0,
            legal: const <int>{0},
            onTokenTap: tapped.add,
            onIllegalTokenTap: shaken.add,
          ),
        );
        await tester.pump();

        // Kills: adding the mark's widget to the token layer displacing or
        // hiding the existing legal ring (e.g. by changing paint order so
        // the mark now sits above the ring instead of within the disc).
        expect(
          find.byKey(const Key('board-legal-ring-0-0')),
          findsOneWidget,
          reason:
              'board-legal-ring-0-0 must still be drawn for a legal token '
              'once the mark is added (seed: seat=0, token=0, progress=5)',
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('token-0-0')),
            matching: find.byType(SeatMark),
          ),
          findsOneWidget,
          reason:
              'token-0-0 must also carry its own SeatMark at the same time '
              'as the legal ring (seed: seat=0, token=0, progress=5)',
        );

        await tester.tap(find.byKey(const Key('board-token-hit-0-0')));
        await tester.pump();

        // Kills: the mark's own widget (or an ExcludeSemantics/painting
        // wrapper around it) becoming opaque to hit testing and stealing
        // the tap meant for board-token-hit-0-0, the same failure mode
        // test/board_safe_squares_test.dart's own case guards against for
        // the safe-square star.
        expect(
          tapped,
          <int>[0],
          reason:
              'tapping board-token-hit-0-0 must call onTokenTap exactly '
              'once with token 0 even with the seat mark now drawn on the '
              'token; got $tapped (seed: seat=0, token=0, progress=5)',
        );
        expect(
          shaken,
          isEmpty,
          reason:
              'onIllegalTokenTap must not fire for this legal tap; got '
              '$shaken (seed: seat=0, token=0, progress=5)',
        );
      },
    );
  });
}
