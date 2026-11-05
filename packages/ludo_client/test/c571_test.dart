// Screen proofs for work/ludo/orders/571-finished-dice-at-rest.md, contract
// D1 to D3: after the last move no die looks live. Written from that contract
// alone; the implementation is built in parallel in a tree this file's author
// has not read.
//
// A real GameScreen over a real RoomController on FakeTransport, driven
// through test/support/roll_tray_harness.dart with the server's own frames
// (`rolled`, `moved`, `game_over`, `room`). Nothing is mocked but the socket
// and the feedback service. The die under the board is read off the `GameDie`
// widget (`idleOpacity`, `enabled`, `onTap`); another seat's die is read off
// the `SeatDieView` the board draws in that seat's yard (`die.active`).
//
// Every case is a fixed list of frames, there is no seed. A failure line
// names the case, the step, what the widget held, and every frame pushed so
// far in order, which is the whole reproduction. Time is fake and is only ever
// advanced in bounded pumps (one token step, or one millisecond), never
// settled while a turn timer is live.
//
// The held game: seat 0 holds a token on 51 and one on 10, the turn is seat
// 0's roll, then a `rolled` 6 with both tokens legal (so no auto-move hold
// arms), then `moved` 51 to 57 (six squares of travel), then `game_over`
// naming seat 0. Viewed from seat 0 that is the winner's screen; viewed from
// seat 1 it is the loser's.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/game_die.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/seat_die.dart';

import 'support/roll_tray_harness.dart';

// The idle opacity C-468 D7 already uses for a die that cannot be used.
const double _idle = 0.45;

const Key _winnerKey = Key('game-screen-winner');

const List<int> _winnerTokens = <int>[51, 10, -1, -1];

/// One mounted GameScreen and the log that makes a failure reproducible.
class _Game {
  _Game(this.tester, this.drive, this.name, this.mySeat);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String name;
  final int mySeat;
  final List<String> frames = <String>[];

  /// Sent-frame count at mount; everything after it came from the screen.
  int sentAtMount = 0;

  /// True once [release] ran, so the teardown does not dispose twice.
  bool released = false;

  /// Unmounts the screen and disposes the controller now, for a case that
  /// sent a request whose own timer would otherwise outlive the test.
  Future<void> release() async {
    released = true;
    await releaseGame(tester, drive);
  }

  static Future<_Game> start(
    WidgetTester tester, {
    required String name,
    int mySeat = 0,
    Map<String, Object?>? turn,
    String state = 'PLAYING',
    int? winner,
  }) async {
    final RollTrayDrive drive = await connectPlaying(
      tester,
      mySeat: mySeat,
      state: state,
      winner: winner,
      turn:
          turn ??
          turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
      seats: twoSeats(mine: _winnerTokens),
    );
    await mountGame(tester, drive);
    final _Game game = _Game(tester, drive, name, mySeat);
    game.sentAtMount = drive.transport.sentRaw.length;
    addTearDown(() {
      if (!game.released) {
        drive.controller.dispose();
      }
    });
    return game;
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    frames.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  String why(String step, String expected, String got) =>
      'C-571 $name (viewed from seat $mySeat) at "$step": expected $expected, '
      'got $got. Frames pushed in order: '
      '${frames.isEmpty ? '<none, room snapshot only>' : frames.join(' -> ')}. '
      'Fixed frames, no seed: replay them on a GameScreen over a '
      'RoomController on FakeTransport.';

  /// Seat 0 rolls a 6 with both tokens legal.
  Future<void> rollSix() async {
    await push('rolled', <String, Object?>{
      'seat': 0,
      'value': 6,
      'legal': const <int>[0, 1],
      'deadline_ms': rollTrayDeadlineMs,
      'k': 1,
      'reveal': rollTrayReveal,
      'queue': const <int>[6],
      'legal_by_face': <Map<String, Object?>>[
        faceLegal(6, const <int>[0, 1]),
      ],
    });
    // Let the thrown die settle: bounded fake-time pumps, no settle.
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Seat 0 moves token 0 from 51 to 57: six squares of travel.
  Future<void> winningMove() async {
    await push('moved', <String, Object?>{
      'seat': 0,
      'token': 0,
      'from': 51,
      'to': 57,
      'captured': const <Object?>[],
      'extra_roll': false,
      'face': 6,
    });
  }

  Future<void> gameOver() async {
    await push('game_over', <String, Object?>{
      'winner': 0,
      'verify_url': 'https://c571-test.invalid/verify/1',
    });
  }

  // --- reads ---------------------------------------------------------------

  bool get dieInTree => find.byType(GameDie).evaluate().isNotEmpty;

  bool get cardUp => find.byKey(_winnerKey).evaluate().isNotEmpty;

  GameDie? get die =>
      dieInTree ? tester.widget<GameDie>(find.byType(GameDie)) : null;

  /// The `SeatDie` the board hands the painter for [seat], or null when the
  /// board draws none.
  SeatDie? seatDie(int seat) {
    for (final Element e in find.byType(SeatDieView).evaluate()) {
      final SeatDie d = (e.widget as SeatDieView).die;
      if (d.seat == seat) {
        return d;
      }
    }
    return null;
  }

  String _describeDie() {
    final GameDie? d = die;
    return d == null
        ? 'no GameDie in the tree (end card ${cardUp ? 'up' : 'not up'})'
        : 'idleOpacity ${d.idleOpacity}, enabled ${d.enabled}, '
              'onTap ${d.onTap == null ? 'null' : 'set'}';
  }

  /// The die is live: full opacity and enabled.
  void expectDieLive(String step) {
    final GameDie? d = die;
    expect(d, isNotNull, reason: why(step, 'a GameDie', _describeDie()));
    expect(
      d!.idleOpacity,
      1.0,
      reason: why(step, 'idleOpacity 1', _describeDie()),
    );
    expect(
      d.enabled,
      isTrue,
      reason: why(step, 'enabled true', _describeDie()),
    );
  }

  /// The die is at rest: idle opacity, not enabled, no tap handler.
  void expectDieAtRest(String step) {
    final GameDie? d = die;
    expect(d, isNotNull, reason: why(step, 'a GameDie', _describeDie()));
    expect(
      d!.idleOpacity,
      _idle,
      reason: why(step, 'idleOpacity $_idle', _describeDie()),
    );
    expect(
      d.enabled,
      isFalse,
      reason: why(step, 'enabled false', _describeDie()),
    );
    expect(d.onTap, isNull, reason: why(step, 'onTap null', _describeDie()));
  }

  void expectCardAbsent(String step) {
    expect(cardUp, isFalse, reason: why(step, 'no end card yet', 'card up'));
    expect(
      dieInTree,
      isTrue,
      reason: why(
        step,
        'the playing body (GameDie) still on screen, the end hold in effect',
        _describeDie(),
      ),
    );
  }

  Future<void> pumpSquares(int squares) async {
    for (int i = 0; i < squares; i++) {
      await tester.pump(kTokenStepDuration);
    }
  }

  /// Fake time in bounded 100 ms steps until the end card is up, at most
  /// the hold limit plus a second.
  Future<void> pumpToCard(String step) async {
    final Duration cap = kEndCardHoldLimit + const Duration(seconds: 1);
    Duration spent = Duration.zero;
    while (!cardUp && spent < cap) {
      await tester.pump(const Duration(milliseconds: 100));
      spent += const Duration(milliseconds: 100);
    }
    expect(
      cardUp,
      isTrue,
      reason: why(step, 'the end card within ${cap.inMilliseconds} ms', 'none'),
    );
  }

  List<String> sentSinceMount() => sentTypesSince(drive.transport, sentAtMount);
}

/// The winner's game up to and including `game_over`, mid-hold: the board is
/// still up, the winning token is two squares into its six.
Future<_Game> _heldWinnerGame(
  WidgetTester tester, {
  required String name,
  int mySeat = 0,
}) async {
  final _Game g = await _Game.start(tester, name: name, mySeat: mySeat);
  await g.rollSix();
  await g.winningMove();
  await g.gameOver();
  g.expectCardAbsent('fixture: right after game_over');
  return g;
}

void main() {
  group('C-571 D1: the die under the board at rest once the room is finished', () {
    // Kills: a die that keeps the seat-colour frame and full opacity for the
    // winner during the hold and after it.
    testWidgets(
      'C-571 D1 winner, live: after game_over the die is at 0.45 and not '
      'enabled, through the hold and after the card',
      (tester) async {
        final _Game g = await _heldWinnerGame(tester, name: 'D1 winner live');
        g.expectDieAtRest('right after game_over');

        await g.pumpSquares(2);
        g.expectCardAbsent('fixture: two squares into the walk');
        g.expectDieAtRest('mid hold, two squares of six walked');

        await g.pumpSquares(3);
        g.expectCardAbsent('fixture: five squares into the walk');
        g.expectDieAtRest('mid hold, five squares of six walked');

        await g.pumpSquares(1);
        g.expectCardAbsent('fixture: landed, inside the dwell');
        g.expectDieAtRest('landed on 57, inside the dwell');

        await g.pumpToCard('end card after the dwell');
        if (g.dieInTree) {
          g.expectDieAtRest('after the end card is up');
        }
      },
    );

    // Proves the finder reads the widget the player sees: the same GameDie
    // is live on my own turn awaiting a roll, and the contract's "before the
    // room is finished, both dice behave as before" holds on the way there.
    testWidgets(
      'C-571 D1 control: on my own turn awaiting a roll the die is at 1 and '
      'enabled; once I have rolled it is at 1 and not enabled',
      (tester) async {
        final _Game g = await _Game.start(tester, name: 'D1 control');
        g.expectDieLive('my turn, await_roll, before any frame');
        expect(
          g.die!.onTap,
          isNotNull,
          reason: g.why('my turn, await_roll', 'onTap set', g._describeDie()),
        );

        await g.rollSix();
        final GameDie? d = g.die;
        expect(
          d,
          isNotNull,
          reason: g.why('after my roll', 'a GameDie', g._describeDie()),
        );
        expect(
          d!.idleOpacity,
          1.0,
          reason: g.why(
            'after my roll, my await_move',
            'idleOpacity 1 (the turn is still mine)',
            g._describeDie(),
          ),
        );
        expect(
          d.enabled,
          isFalse,
          reason: g.why(
            'after my roll, my await_move',
            'enabled false (a token is to be moved, not the die)',
            g._describeDie(),
          ),
        );
      },
    );

    // Control for the no-send case: the same tap, before the room is
    // finished, does reach the transport. Without it a tap that misses the
    // die would pass the next case for the wrong reason.
    testWidgets(
      'C-571 D1 no send control: a tap on the live die sends one roll',
      (tester) async {
        final _Game g = await _Game.start(tester, name: 'D1 no send control');
        g.expectDieLive('my turn, await_roll');
        await tester.tap(find.byType(GameDie));
        await tester.pump();
        final List<String> sent = g.sentSinceMount();
        await g.release();
        expect(
          sent.where((String t) => t == 'roll').length,
          1,
          reason: g.why(
            'tap on the live die',
            'exactly one roll frame sent',
            'sent frame types $sent',
          ),
        );
      },
    );

    testWidgets(
      'C-571 D1 no send: a tap on the die during the end hold sends no roll',
      (tester) async {
        final _Game g = await _heldWinnerGame(tester, name: 'D1 no send');
        await g.pumpSquares(2);
        g.expectCardAbsent('fixture: mid hold');
        final int before = g.drive.transport.sentRaw.length;
        await tester.tap(find.byType(GameDie), warnIfMissed: false);
        await tester.pump();
        final List<String> sent = sentTypesSince(g.drive.transport, before);
        expect(
          sent,
          isEmpty,
          reason: g.why(
            'tap on the die mid hold',
            'nothing sent to the server',
            'sent frame types $sent',
          ),
        );
      },
    );

    // A snapshot that arrives already finished, the last turn naming my seat.
    // On d706d4c a resumed FINISHED room draws the end card at once (no hold
    // is armed without a live game_over and travel), so there is no die under
    // the board to read. The case asserts the die at rest whenever one is
    // drawn and otherwise that the end card stands in its place; on the base
    // it therefore passes through the card branch. The next case reaches the
    // same contract line (turn.phase finished) through a room that still
    // draws its playing body.
    testWidgets(
      'C-571 D1 resume: a finished room snapshot (state FINISHED, last turn '
      'mine) leaves no live die',
      (tester) async {
        final _Game g = await _Game.start(
          tester,
          name: 'D1 resume, state FINISHED',
          state: 'FINISHED',
          winner: 0,
          turn: turnJson(seat: 0, phase: 'finished', k: 3),
        );
        if (g.dieInTree) {
          g.expectDieAtRest('room snapshot already FINISHED, die drawn');
        } else {
          expect(
            g.cardUp,
            isTrue,
            reason: g.why(
              'room snapshot already FINISHED',
              'a GameDie at rest, or the end card instead of it',
              g._describeDie(),
            ),
          );
        }
      },
    );

    // The other half of "state == finished, or turn.phase == finished": the
    // room still says PLAYING but the last turn is finished, so the playing
    // body is on screen with a die in it.
    testWidgets(
      'C-571 D1 resume: a snapshot whose last turn is finished (room state '
      'still PLAYING, turn names my seat) leaves the die at 0.45, not enabled',
      (tester) async {
        final _Game g = await _Game.start(
          tester,
          name: 'D1 resume, turn.phase finished',
          turn: turnJson(seat: 0, phase: 'finished', k: 3),
        );
        g.expectDieAtRest('snapshot with turn.phase finished, my seat');
      },
    );

    testWidgets(
      'C-571 D1 resume: a finished-turn snapshot read from the other seat '
      'keeps the die at 0.45, not enabled',
      (tester) async {
        final _Game g = await _Game.start(
          tester,
          name: 'D1 resume, loser view',
          mySeat: 1,
          turn: turnJson(seat: 0, phase: 'finished', k: 3),
        );
        g.expectDieAtRest('snapshot with turn.phase finished, other seat');
      },
    );
  });

  group('C-571 D2: the other seats\' dice once the room is finished', () {
    // Kills: a SeatDie built active for whichever seat the last turn named.
    testWidgets(
      'C-571 D2 loser, live: the winner\'s seat die is active while she '
      'holds the turn and not active after game_over, through the hold',
      (tester) async {
        final _Game g = await _Game.start(
          tester,
          name: 'D2 loser live',
          mySeat: 1,
        );
        final SeatDie? before = g.seatDie(0);
        expect(
          before,
          isNotNull,
          reason: g.why(
            'control, seat 0 awaiting her roll',
            'a SeatDieView for seat 0',
            'none drawn',
          ),
        );
        expect(
          before!.active,
          isTrue,
          reason: g.why(
            'control, seat 0 awaiting her roll',
            'seat 0 SeatDie.active true',
            'active ${before.active}',
          ),
        );

        await g.rollSix();
        final SeatDie? rolled = g.seatDie(0);
        expect(
          rolled?.active,
          isTrue,
          reason: g.why(
            'control, seat 0 has rolled and holds the turn',
            'seat 0 SeatDie.active true',
            rolled == null ? 'no SeatDieView' : 'active ${rolled.active}',
          ),
        );

        await g.winningMove();
        await g.gameOver();
        g.expectCardAbsent('fixture: right after game_over');
        _expectSeatDieAtRest(g, 'right after game_over');

        await g.pumpSquares(2);
        g.expectCardAbsent('fixture: two squares into the walk');
        _expectSeatDieAtRest(g, 'mid hold, two squares of six walked');

        await g.pumpSquares(4);
        g.expectCardAbsent('fixture: landed, inside the dwell');
        _expectSeatDieAtRest(g, 'landed on 57, inside the dwell');
      },
    );

    // The same contract line for the viewer who is not the winner, by way
    // of the die under the board: it was already idle while seat 0 held the
    // turn and must stay exactly that.
    testWidgets(
      'C-571 D2 loser, live: the loser\'s own die stays at 0.45 and not '
      'enabled through the hold',
      (tester) async {
        final _Game g = await _Game.start(
          tester,
          name: 'D2 loser own die',
          mySeat: 1,
        );
        await g.rollSix();
        await g.winningMove();
        await g.gameOver();
        g.expectCardAbsent('fixture: right after game_over');
        g.expectDieAtRest('loser, right after game_over');
        await g.pumpSquares(2);
        g.expectDieAtRest('loser, mid hold');
      },
    );
  });

  group('C-571 D3: nothing else changes', () {
    // Kills: D1/D2 satisfied by cutting the hold. Same numbers as
    // test/end_hold_test.dart: the card is absent through the walk and the
    // dwell and present exactly kEndCardDwell after the landing.
    testWidgets('C-571 D3: the end card still appears only after the walk and '
        'kEndCardDwell', (tester) async {
      final _Game g = await _heldWinnerGame(tester, name: 'D3 hold');

      await g.pumpSquares(5);
      g.expectCardAbsent('five of six squares walked');

      await g.pumpSquares(1);
      g.expectCardAbsent('the sixth square landed, dwell just started');

      Duration left = kEndCardDwell - const Duration(milliseconds: 1);
      while (left > Duration.zero) {
        final Duration step = left > const Duration(milliseconds: 200)
            ? const Duration(milliseconds: 200)
            : left;
        await tester.pump(step);
        left -= step;
      }
      g.expectCardAbsent('one millisecond short of kEndCardDwell');

      await tester.pump(const Duration(milliseconds: 1));
      expect(
        g.cardUp,
        isTrue,
        reason: g.why(
          'exactly kEndCardDwell after the landing',
          'the end card up',
          'card not up',
        ),
      );
      expect(
        find.byKey(const Key('game-die')).evaluate(),
        isEmpty,
        reason: g.why(
          'exactly kEndCardDwell after the landing',
          'the playing body gone with the card',
          'game-die still in the tree',
        ),
      );
    });
  });
}

void _expectSeatDieAtRest(_Game g, String step) {
  final SeatDie? d = g.seatDie(0);
  expect(
    d,
    isNotNull,
    reason: g.why(step, 'a SeatDieView for seat 0', 'none drawn'),
  );
  expect(
    d!.active,
    isFalse,
    reason: g.why(
      step,
      'seat 0 SeatDie.active false (the room is finished)',
      'active ${d.active}, face ${d.face}',
    ),
  );
}
