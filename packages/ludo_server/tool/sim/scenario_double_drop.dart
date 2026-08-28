// Scenario 3 of order 014: `double-drop`. The same game, but two non-host
// clients drop at the same moment and both reconnect. Reaches a winner.
//
// "At the same moment" is implemented as: both sockets are closed before
// either reconnect is started (two `close()` calls with no `await` between
// them), and both reconnects are then raced with `Future.wait` rather than
// run one after the other -- the server sees both seats go and come back
// concurrently, not sequentially.
//
// Requires at least 3 players (host plus two others to drop). With fewer,
// this scenario fails cleanly naming the shortfall rather than dropping the
// same seat twice, which would not be a "double" drop.

import 'dart:async';

import 'fairness.dart';
import 'game.dart';
import 'scenario.dart';
import 'wire.dart';

Future<ScenarioResult> runDoubleDrop(
  Uri target,
  int players, {
  Duration perFrameTimeout = const Duration(seconds: 20),
}) async {
  const String name = 'double-drop';
  final List<SimSocket> allSockets = <SimSocket>[];
  try {
    if (players < 3) {
      return ScenarioResult(
        name: name,
        passed: false,
        detail: 'double-drop requires at least 3 players (host plus two '
            'others to drop); got --players $players',
      );
    }

    final GameSetup setup = await setUpGame(target, players);
    allSockets.addAll(setup.allSockets);

    final List<int> nonHostSeats = setup.seats.keys
        .where((int seat) => seat != setup.hostSeat)
        .toList()
      ..sort();
    final int targetA = nonHostSeats[0];
    final int targetB = nonHostSeats[1];

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

      final Future<void> closeA = dropSocketOnly(targetA, setup.seats);
      final Future<void> closeB = dropSocketOnly(targetB, setup.seats);
      await Future.wait<void>(<Future<void>>[closeA, closeB]);

      final Future<void> reconnectA = reconnectSeat(
        seatIndex: targetA,
        seats: setup.seats,
        target: target,
        code: setup.code,
        expectedChainCommit: setup.chainCommit,
        allSockets: allSockets,
        attempt: 1,
      );
      final Future<void> reconnectB = reconnectSeat(
        seatIndex: targetB,
        seats: setup.seats,
        target: target,
        code: setup.code,
        expectedChainCommit: setup.chainCommit,
        allSockets: allSockets,
        attempt: 1,
      );
      await Future.wait<void>(<Future<void>>[reconnectA, reconnectB]);
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
        'the double-drop trigger ever fired; seats $targetA and $targetB '
        'were never dropped, so this run did not test what it claims to',
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
          'verified, seats $targetA and $targetB dropped simultaneously and '
          'both reconnected, all $players clients confirmed game_over',
    );
  } catch (error) {
    return ScenarioResult(name: name, passed: false, detail: error.toString());
  } finally {
    for (final SimSocket socket in allSockets) {
      await socket.close();
    }
  }
}
