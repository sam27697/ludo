// Scenario 2 of order 014: `reconnect`. The same game as `full-game`, but
// partway through, one non-host client's socket is closed hard, and that
// client reconnects with its seat token, receives a room snapshot, takes
// the same seat, and the game still reaches a winner. docs/PROTOCOL.md
// section 8 is the reconnection contract this exercises: `resume` with
// `code` and `seat_token`, answered with the full room snapshot, no
// `join_room` involved.
//
// The drop is triggered on the first `turn` frame observed once at least
// one roll has already been verified against the chain -- guaranteeing the
// drop happens mid-game (after real play, with a real chain link already
// published) rather than in the lobby, per the work order's explicit
// requirement.

import 'fairness.dart';
import 'game.dart';
import 'scenario.dart';
import 'wire.dart';

Future<ScenarioResult> runReconnect(
  Uri target,
  int players, {
  Duration perFrameTimeout = const Duration(seconds: 20),
}) async {
  const String name = 'reconnect';
  final List<SimSocket> allSockets = <SimSocket>[];
  try {
    if (players < 2) {
      throw ScenarioFailure(
        'reconnect requires at least 2 players (host + 1 other); got '
        '--players $players',
      );
    }

    final GameSetup setup = await setUpGame(target, players);
    allSockets.addAll(setup.allSockets);

    final int targetSeat = setup.seats.keys
        .where((int seat) => seat != setup.hostSeat)
        .reduce((int a, int b) => a < b ? a : b);

    final FairnessTracker fairness = FairnessTracker(
      chainCommit: setup.chainCommit,
      gameId: setup.gameId,
      clientSeeds: setup.clientSeeds,
    );

    bool dropped = false;
    Future<void> onTurnFrame(int turnSeat, int rollsSoFar) async {
      if (dropped || rollsSoFar < 1) {
        return;
      }
      dropped = true;
      await dropSocketOnly(targetSeat, setup.seats);
      await reconnectSeat(
        seatIndex: targetSeat,
        seats: setup.seats,
        target: target,
        code: setup.code,
        expectedChainCommit: setup.chainCommit,
        allSockets: allSockets,
        attempt: 1,
      );
    }

    final Seat observerSeat = setup.seats[setup.hostSeat]!;
    final PlayResult result = await playGame(
      observer: observerSeat.socket,
      seats: setup.seats,
      fairness: fairness,
      initialTurnSeat: setup.initialTurnSeat,
      onTurnFrame: onTurnFrame,
      perFrameTimeout: perFrameTimeout,
    );

    if (!dropped) {
      throw ScenarioFailure(
        'the game reached game_over (winner=seat ${result.winner}) before '
        'the reconnect trigger ever fired; the drop of seat $targetSeat '
        'never happened, so this run did not test what it claims to',
      );
    }

    // The observer already proved it received game_over: that is exactly
    // how playGame learned the winner, and its copy was consumed from the
    // queue in the process. Only the other seats' sockets, never read
    // during play, still need checking.
    for (final Seat seat in setup.seats.values) {
      if (identical(seat.socket, observerSeat.socket)) {
        continue;
      }
      await assertReceivedGameOver(seat.socket, result.winner);
    }

    return ScenarioResult(
      name: name,
      passed: true,
      detail: 'winner=seat ${result.winner}, ${result.rollsVerified} rolls '
          'verified, seat $targetSeat dropped and reconnected mid-game via '
          'resume, all $players clients confirmed game_over',
    );
  } catch (error) {
    return ScenarioResult(name: name, passed: false, detail: error.toString());
  } finally {
    for (final SimSocket socket in allSockets) {
      await socket.close();
    }
  }
}
