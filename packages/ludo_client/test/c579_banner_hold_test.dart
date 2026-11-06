// Screen proof for C-579 D5 as amended by the RESPEC (order 579t): the turn
// banner holds its line while the controller's placeholder turn is up, in
// the one place D5 names: the own-seat plain roll line. The C-568 extra-roll
// lines are not held (item 6(b)). Written from the contract's
// text alone. A real GameScreen over a real RoomController on FakeTransport,
// every state a decoded wire frame, the harness from
// support/roll_tray_harness.dart.
//
// The placeholder is what the controller builds after `moved` and
// `turn_passed` until the `turn` frame behind them arrives. Here that gap is
// kept open on purpose: the frame is not pushed until the held line has been
// read at every frame of a long pump. All timing is `tester.pump(Duration)`
// on the fake clock.
//
// What the banner reads once the `turn` has arrived is the pre-C-579 reading
// for that turn, so the proof that the line returns to the live turn does not
// depend on the hold. Item 7 starts from an await_move turn only: the
// void-roll flow (rolled with no legal move, then turn_passed) is not
// asserted, since there the last non-settling line is already the roll line.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _bannerKey = Key('game-screen-turn-banner');

const List<int> _mine = <int>[3, 10, 20, 30];
const List<int> _theirs = <int>[-1, -1, 40, -1];

/// Two legal tokens on one face: the plain "Move a token" line, no hold.
Map<String, Object?> _moveTurn() => turnJson(
  seat: 0,
  phase: 'await_move',
  k: 1,
  value: 4,
  legal: const <int>[1, 3],
);

/// Two legal tokens, face 4 now and face 3 still queued behind it.
Map<String, Object?> _queuedMoveTurn() => turnJson(
  seat: 0,
  phase: 'await_move',
  k: 2,
  value: 4,
  legal: const <int>[1, 3],
  queue: const <int>[4, 3],
  legalByFace: <Map<String, Object?>>[
    faceLegal(4, const <int>[1, 3]),
    faceLegal(3, const <int>[1, 3]),
  ],
);

class _Rig {
  _Rig(this.s, this.locale);

  final Scn s;
  final Locale locale;

  WidgetTester get tester => s.tester;

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  String get banner {
    final Finder f = find.byKey(_bannerKey);
    if (!tester.any(f)) {
      fail(s.why('game-screen-turn-banner is on screen'));
    }
    return tester.widget<Text>(f).data!;
  }

  /// Pumps [total] in 16 ms frames; after each, [check] reads the banner.
  Future<void> pumpChecking(
    Duration total,
    void Function(String banner, int at) check,
  ) async {
    s.steps.add('pump ${total.inMilliseconds}ms checking the banner');
    int at = 0;
    while (at < total.inMilliseconds) {
      await tester.pump(kC468Frame);
      at += kC468Frame.inMilliseconds;
      s.clockMs += kC468Frame.inMilliseconds;
      check(banner, at);
    }
  }
}

Future<_Rig> _rig(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  Map<String, Object?>? turn,
}) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await mountScreen(
    tester,
    locale: locale,
    turn: turn ?? _moveTurn(),
    seats: <Map<String, Object?>>[
      seatJson(0, name: 'Sam', tokens: _mine),
      seatJson(2, name: 'Bob', tokens: _theirs),
    ],
  );
  return _Rig(Scn('$name [${locale.languageCode}]', tester, drive), locale);
}

Future<void> _pushMove(_Rig r, {bool capture = false}) => r.s.push(
  'moved',
  movedFrame(
    0,
    1,
    10,
    14,
    captured: <Map<String, int>>[
      if (capture) <String, int>{'seat': 2, 'token': 2},
    ],
    extraRoll: capture,
  ),
);

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String lang = locale.languageCode;

    // -----------------------------------------------------------------
    // Item 6(a): a plain move with more faces queued keeps the move line.
    // -----------------------------------------------------------------
    testWidgets(
      'C-579 D5 [$lang]: item 6(a): a plain move (no capture, no extra roll) '
      'with faces still queued and no turn yet: the banner reads '
      'gameYourTurnMove at every frame, never gameYourTurnRoll, and still '
      'does when the turn arrives',
      (tester) async {
        final _Rig r = await _rig(
          tester,
          name: 'C-579 item 6a plain move, faces queued',
          locale: locale,
          turn: _queuedMoveTurn(),
        );
        try {
          final AppLocalizations loc = r.loc;
          expect(
            r.banner,
            loc.gameYourTurnMove,
            reason: r.s.why('fixture: my move to make reads gameYourTurnMove'),
          );
          await _pushMove(r);
          expect(
            r.banner,
            loc.gameYourTurnMove,
            reason: r.s.why(
              'on the frame after moved the banner still reads '
              'gameYourTurnMove (it read "${r.banner}")',
            ),
          );
          await r.pumpChecking(const Duration(milliseconds: 1500), (
            String banner,
            int at,
          ) {
            expect(
              banner,
              isNot(loc.gameYourTurnRoll),
              reason: r.s.why(
                'never gameYourTurnRoll before the turn frame, at +$at ms '
                'after moved; it read "$banner"',
              ),
            );
            expect(
              banner,
              loc.gameYourTurnMove,
              reason: r.s.why(
                'the held line is gameYourTurnMove at +$at ms after moved; '
                'it read "$banner"',
              ),
            );
          });
          await r.s.push('turn', <String, Object?>{
            'seat': 0,
            'phase': 'await_move',
            'deadline_ms': rollTrayDeadlineMs,
            'value': 3,
            'legal': const <int>[1, 3],
            'queue': const <int>[3],
          });
          await r.s.pump(const Duration(milliseconds: 100));
          expect(
            r.banner,
            loc.gameYourTurnMove,
            reason: r.s.why(
              'the turn frame (await_move, next queued face) reads '
              'gameYourTurnMove; it read "${r.banner}"',
            ),
          );
        } finally {
          await releaseGame(tester, r.s.drive);
        }
      },
    );

    // -----------------------------------------------------------------
    // Item 6(b): a capture with extra_roll keeps C-568's own line.
    // -----------------------------------------------------------------
    testWidgets(
      'C-579 D5 [$lang]: item 6(b): a capturing move with extra_roll true '
      'and no turn yet: the banner reads gameRollAgainCapture right after '
      'moved and at every frame, and after the turn',
      (tester) async {
        final _Rig r = await _rig(
          tester,
          name: 'C-579 item 6b capture with extra_roll',
          locale: locale,
        );
        try {
          final AppLocalizations loc = r.loc;
          expect(
            r.banner,
            loc.gameYourTurnMove,
            reason: r.s.why('fixture: my move to make reads gameYourTurnMove'),
          );
          await _pushMove(r, capture: true);
          expect(
            r.banner,
            loc.gameRollAgainCapture,
            reason: r.s.why(
              'right after moved the banner reads gameRollAgainCapture (it '
              'read "${r.banner}")',
            ),
          );
          await r.pumpChecking(const Duration(milliseconds: 1500), (
            String banner,
            int at,
          ) {
            expect(
              banner,
              loc.gameRollAgainCapture,
              reason: r.s.why(
                'gameRollAgainCapture before the turn frame, at +$at ms '
                'after moved; it read "$banner"',
              ),
            );
          });
          await r.s.push('turn', turnFrame(0));
          await r.s.pump(const Duration(milliseconds: 100));
          expect(
            r.banner,
            loc.gameRollAgainCapture,
            reason: r.s.why(
              'the turn frame (await_roll, same seat, after a capture) '
              'reads gameRollAgainCapture; it read "${r.banner}"',
            ),
          );
        } finally {
          await releaseGame(tester, r.s.drive);
        }
      },
    );

    // -----------------------------------------------------------------
    // Item 7: after turn_passed, before the next turn.
    // -----------------------------------------------------------------
    for (final String reason in const <String>[
      'no_legal_move',
      'three_sixes',
    ]) {
      testWidgets(
        'C-579 D5 [$lang]: turn_passed ($reason) for my seat and no turn yet: '
        'the banner never reads gameYourTurnRoll, then the next seat\'s '
        'waiting line',
        (tester) async {
          final _Rig r = await _rig(
            tester,
            name: 'C-579 item 7 $reason',
            locale: locale,
          );
          try {
            final AppLocalizations loc = r.loc;
            final String before = r.banner;
            expect(
              before,
              loc.gameYourTurnMove,
              reason: r.s.why('fixture: the line before is gameYourTurnMove'),
            );
            await r.s.push('turn_passed', <String, Object?>{
              'seat': 0,
              'reason': reason,
            });
            expect(
              r.banner,
              isNot(loc.gameYourTurnRoll),
              reason: r.s.why(
                'never gameYourTurnRoll on the frame after turn_passed; it '
                'read "${r.banner}"',
              ),
            );
            await r.pumpChecking(const Duration(milliseconds: 1500), (
              String banner,
              int at,
            ) {
              expect(
                banner,
                isNot(loc.gameYourTurnRoll),
                reason: r.s.why(
                  'never gameYourTurnRoll before the turn frame, at +$at ms '
                  'after turn_passed; it read "$banner"',
                ),
              );
              expect(
                banner,
                before,
                reason: r.s.why(
                  'the line from before the pass is held at +$at ms; it '
                  'read "$banner"',
                ),
              );
            });
            await r.s.push('turn', turnFrame(2));
            await r.s.pump(const Duration(milliseconds: 100));
            expect(
              r.banner,
              loc.gameWaitingForPlayer('Bob'),
              reason: r.s.why('then the next seat\'s waiting line'),
            );
          } finally {
            await releaseGame(tester, r.s.drive);
          }
        },
      );
    }

    // -----------------------------------------------------------------
    // Item 8 and the two exceptions: stale and finished beat the hold.
    // -----------------------------------------------------------------
    for (final String cause in const <String>['moved', 'turn_passed']) {
      testWidgets(
        'C-579 D5 [$lang]: while settling after $cause a dropped socket '
        'shows gameYourTurnStale, not the held line',
        (tester) async {
          final _Rig r = await _rig(
            tester,
            name: 'C-579 item 8 stale after $cause',
            locale: locale,
          );
          try {
            final AppLocalizations loc = r.loc;
            if (cause == 'moved') {
              await _pushMove(r);
            } else {
              await r.s.push('turn_passed', <String, Object?>{
                'seat': 0,
                'reason': 'no_legal_move',
              });
            }
            r.s.steps.add('far side ends the socket');
            r.s.drive.transport.endFromFarSide();
            await tester.pump();
            await tester.pump();
            await r.pumpChecking(const Duration(milliseconds: 500), (
              String banner,
              int at,
            ) {
              expect(
                banner,
                loc.gameYourTurnStale,
                reason: r.s.why(
                  'stale beats a held line: gameYourTurnStale at +$at ms '
                  'after the drop; it read "$banner"',
                ),
              );
            });
          } finally {
            await releaseGame(tester, r.s.drive);
          }
        },
      );
    }

    testWidgets(
      'C-579 D5 [$lang]: while settling a finished game shows gameOverEnded, '
      'not the held line',
      (tester) async {
        final _Rig r = await _rig(
          tester,
          name: 'C-579 finished beats the hold',
          locale: locale,
        );
        try {
          final AppLocalizations loc = r.loc;
          await _pushMove(r);
          await r.s.push('game_over', gameOverFrame(0));
          await r.s.pump(const Duration(milliseconds: 100));
          expect(
            r.banner,
            loc.gameOverEnded,
            reason: r.s.why(
              'a finished room reads gameOverEnded; it read "${r.banner}"',
            ),
          );
        } finally {
          await releaseGame(tester, r.s.drive);
        }
      },
    );
  }
}
