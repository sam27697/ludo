// Scenario 1 of order 014: `full-game`. Client A creates a room for
// `--players` seats and receives the room code and the chain commitment.
// Clients B, C and D join by that code. A starts the game. All four play to
// a natural winner, each seat always sending a legal move the server itself
// said was legal. Must end in a `game_over` frame every one of the clients
// received, naming the same winner, and every `rolled` frame observed along
// the way must satisfy the fairness assertion of docs/PROTOCOL.md sections
// 11.2 and 12 against `package:fair_dice`.

import 'fairness.dart';
import 'game.dart';
import 'scenario.dart';
import 'wire.dart';

Future<ScenarioResult> runFullGame(
  Uri target,
  int players, {
  Duration perFrameTimeout = const Duration(seconds: 20),
}) async {
  const String name = 'full-game';
  final List<SimSocket> allSockets = <SimSocket>[];
  try {
    final GameSetup setup = await setUpGame(target, players);
    allSockets.addAll(setup.allSockets);

    final FairnessTracker fairness = FairnessTracker(
      chainCommit: setup.chainCommit,
      gameId: setup.gameId,
      clientSeeds: setup.clientSeeds,
    );

    final Seat observerSeat = setup.seats[setup.hostSeat]!;
    final PlayResult result = await playGame(
      observer: observerSeat.socket,
      seats: setup.seats,
      fairness: fairness,
      initialTurnSeat: setup.initialTurnSeat,
      perFrameTimeout: perFrameTimeout,
    );

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
          'verified against chain_commit=${setup.chainCommit}, '
          '$players/$players clients confirmed game_over',
    );
  } catch (error) {
    // Deliberately catches everything, not just Exception: a StateError off
    // a socket that closed unexpectedly is exactly as much a scenario
    // failure as a ScenarioFailure or a FairnessBreach, and the work order
    // asks for a reason line either way.
    return ScenarioResult(name: name, passed: false, detail: error.toString());
  } finally {
    for (final SimSocket socket in allSockets) {
      await socket.close();
    }
  }
}
