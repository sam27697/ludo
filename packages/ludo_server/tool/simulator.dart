// The headless four-client simulator of order 014: drives real WebSocket
// clients through a complete Ludo game against a real, separately running
// server process, over the real wire protocol of docs/PROTOCOL.md, and
// exits 0 only if every selected scenario reached the state the protocol
// says it must.
//
//   dart run tool/simulator.dart --target <url>
//       [--scenario all|full-game|reconnect|double-drop|rematch]
//       [--timeout-seconds N] [--players N] [--fetch-record]
//
// See docs/SIMULATOR.md for what each scenario proves and what each
// failure line means.
//
// Order 235 adds `rematch`, docs/PROTOCOL.md section 16: play a full game
// to a natural winner, rematch in the same room, play a second full game to
// a natural winner, and check the two games used distinct `game_id` and
// `chain_commit`. Deliberately not part of `all` -- the gate runs `all`
// under a 210s bound sized for the three scenarios of order 014, and
// stretching that bound to fit a second full game is a later harness
// order's job, not this one's. The whole scenario lives in this file: the
// run 66 file list permitted creating or editing only `rematch_test.dart`,
// one new file under `test/support/`, this file, and `docs/SIMULATOR.md`,
// so the choreography below does not get its own
// `tool/sim/scenario_rematch.dart` the way the other three scenarios each
// do -- see the comment on `runRematch` for what that costs. Run 67's
// RESPEC widened that list by one file, `tool/sim/args.dart`, so `rematch`
// is now a first-class `--scenario` value there too (see the comment on
// `main` below) instead of being stripped out of the argument list by hand.

import 'dart:async';
import 'dart:io';

import 'sim/args.dart';
import 'sim/fairness.dart';
import 'sim/game.dart';
import 'sim/json.dart';
import 'sim/record_check.dart';
import 'sim/scenario.dart';
import 'sim/scenario_double_drop.dart';
import 'sim/scenario_full_game.dart';
import 'sim/scenario_reconnect.dart';
import 'sim/wire.dart';

typedef _ScenarioRunner = Future<ScenarioResult>
    Function(Uri target, int players, {required bool fetchRecord});

const Map<String, _ScenarioRunner> _runners = <String, _ScenarioRunner>{
  'full-game': runFullGame,
  'reconnect': runReconnect,
  'double-drop': runDoubleDrop,
};

Future<void> main(List<String> arguments) async {
  // Run 67: `tool/sim/args.dart`'s `knownScenarios` now carries `rematch`
  // alongside the original three, so `parseArgs` accepts `--scenario
  // rematch` directly like any other name -- no pre-stripping of the raw
  // argument list needed any more. `rematch` is deliberately excluded from
  // `scenariosInAll`, so `args.selectedScenarios` never contains it: the
  // branch below is reached only when `--scenario rematch` was given
  // explicitly, never as part of `--scenario all`.
  final SimulatorArgs args;
  try {
    args = parseArgs(arguments);
  } on ArgsError catch (error) {
    stderr.writeln('simulator: $error');
    stderr.write(usage);
    exitCode = 2;
    return;
  }

  if (args.scenario == 'rematch') {
    final Stopwatch stopwatch = Stopwatch()..start();
    final Duration budget = Duration(seconds: args.timeoutSeconds);
    ScenarioResult result;
    try {
      result = await runRematch(args.target, args.players,
              fetchRecord: args.fetchRecord)
          .timeout(budget);
    } on TimeoutException {
      result = ScenarioResult(
        name: 'rematch',
        passed: false,
        detail: 'did not finish within the overall --timeout-seconds '
            '${args.timeoutSeconds} budget (${stopwatch.elapsed.inSeconds}s '
            'elapsed when the budget ran out)',
      );
    } catch (error) {
      result = ScenarioResult(
        name: 'rematch',
        passed: false,
        detail: 'unhandled exception outside the scenario\'s own error '
            'handling: $error',
      );
    }
    if (result.passed) {
      print('PASS ${result.name} ${result.detail}');
      print('simulator: 1 passed, 0 failed');
      exitCode = 0;
    } else {
      print('FAIL ${result.name} ${result.detail}');
      print('simulator: 0 passed, 1 failed');
      exitCode = 1;
    }
    return;
  }

  final Stopwatch stopwatch = Stopwatch()..start();
  final Duration budget = Duration(seconds: args.timeoutSeconds);

  int passed = 0;
  int failed = 0;

  for (final String scenarioName in args.selectedScenarios) {
    final Duration remaining = budget - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      failed++;
      print(
        'FAIL $scenarioName overall --timeout-seconds ${args.timeoutSeconds} '
        'exceeded before this scenario could start',
      );
      continue;
    }

    final _ScenarioRunner runner = _runners[scenarioName]!;
    ScenarioResult result;
    try {
      result =
          await runner(args.target, args.players, fetchRecord: args.fetchRecord)
              .timeout(remaining);
    } on TimeoutException {
      result = ScenarioResult(
        name: scenarioName,
        passed: false,
        detail: 'did not finish within the overall --timeout-seconds '
            '${args.timeoutSeconds} budget (${stopwatch.elapsed.inSeconds}s '
            'elapsed when the budget ran out)',
      );
    } catch (error) {
      // A scenario function is expected to catch everything itself and
      // return a ScenarioResult; this is a last-resort net so a truly
      // unexpected failure still produces a FAIL line and a non-zero exit
      // rather than an uncaught exception and a silent non-zero exit code
      // with no explanation.
      result = ScenarioResult(
        name: scenarioName,
        passed: false,
        detail: 'unhandled exception outside the scenario\'s own error '
            'handling: $error',
      );
    }

    if (result.passed) {
      passed++;
      print('PASS ${result.name} ${result.detail}');
    } else {
      failed++;
      print('FAIL ${result.name} ${result.detail}');
    }
  }

  print('simulator: $passed passed, $failed failed');
  exitCode = failed == 0 ? 0 : 1;
}

/// Order 235, `rematch`: plays a full game to a natural winner, rematches
/// in the same room (docs/PROTOCOL.md section 16), plays a second full game
/// to a natural winner, and checks the two games used distinct `game_id`
/// and `chain_commit`. Every seat occupied at setup sends `rematch`, in
/// ascending seat order, so the "everyone accepted" auto-start of section
/// 16.4 fires -- no scenario file in this directory calls `set_players` or
/// drops a seat, so every seat from `setUpGame` is still occupied and still
/// connected when the last one accepts.
///
/// Behind `--fetch-record`, fetches and checks both games' stored records,
/// exactly as `full-game` fetches and checks its one record -- off by
/// default for the same reason given in `record_check.dart`'s own header
/// and in `docs/SIMULATOR.md`: a locally started server hands out
/// `verify_url` values on the default production base, and fetching those
/// from a local run would reach `https://provefair.app`, not the server
/// under test. Without the flag this scenario still proves the two records
/// differ (`game_id` and `chain_commit`, read off the wire, never off a
/// fetched record), which is the substance of what the work order's "Goal"
/// asks this scenario to prove; the byte-for-byte record content check is
/// additive, exactly as `--fetch-record` is for every other scenario, and
/// is called out in this order's final report as a point where the order's
/// own wording ("fetches and checks both verify records") reads as
/// unconditional but cannot safely be, for the same reason `--fetch-record`
/// is not unconditional anywhere else in this tool.
Future<ScenarioResult> runRematch(
  Uri target,
  int players, {
  required bool fetchRecord,
  Duration perFrameTimeout = const Duration(seconds: 20),
}) async {
  const String name = 'rematch';
  final List<SimSocket> allSockets = <SimSocket>[];
  try {
    final GameSetup setup = await setUpGame(target, players);
    allSockets.addAll(setup.allSockets);

    final FairnessTracker fairness1 = FairnessTracker(
      chainCommit: setup.chainCommit,
      gameId: setup.gameId,
      clientSeeds: setup.clientSeeds,
    );
    final Seat observerSeat = setup.seats[setup.hostSeat]!;
    final PlayResult result1 = await playGame(
      observer: observerSeat.socket,
      seats: setup.seats,
      fairness: fairness1,
      initialTurnSeat: setup.initialTurnSeat,
      perFrameTimeout: perFrameTimeout,
    );
    for (final Seat seat in setup.seats.values) {
      if (identical(seat.socket, observerSeat.socket)) {
        continue;
      }
      await assertReceivedGameOver(
        seat.socket,
        result1.winner,
        expectedVerifyUrl: result1.verifyUrl,
      );
    }

    // --- rematch handshake, docs/PROTOCOL.md section 16 ---
    final List<int> seatOrder = setup.seats.keys.toList()..sort();
    final int firstRequester = seatOrder.first;

    final String firstRematchId = await setup.seats[firstRequester]!.socket
        .send('rematch', <String, Object?>{});
    Map<String, Object?>? firstRoomData;
    for (final int seatIndex in seatOrder) {
      final SimSocket socket = setup.seats[seatIndex]!.socket;
      final Frame frame = await socket.next(timeout: perFrameTimeout);
      expectFrameType(frame, 'room',
          because: 'seat $firstRequester\'s first rematch request '
              '(FINISHED -> LOBBY, section 16.2), observed by seat $seatIndex');
      final Map<String, Object?> data = frameData(frame);
      final String state = requireString(data, 'state', frame: 'room');
      if (state != 'LOBBY') {
        throw ScenarioFailure(
          'seat $seatIndex saw room.state=$state right after seat '
          '$firstRequester\'s first rematch on a FINISHED room; expected '
          'LOBBY (docs/PROTOCOL.md section 16.2)',
        );
      }
      if (seatIndex == firstRequester) {
        final Object? re = frame['re'];
        if (re != firstRematchId) {
          throw ScenarioFailure(
            'seat $firstRequester\'s own reply to its rematch carried '
            're=$re, expected $firstRematchId',
          );
        }
        firstRoomData = data;
      }
    }
    final Map<String, Object?> firstRoom = firstRoomData!;
    for (final String mustBeNull in <String>[
      'game_id',
      'client_seeds',
      'turn',
      'winner'
    ]) {
      if (firstRoom[mustBeNull] != null) {
        throw ScenarioFailure(
          'room.$mustBeNull=${firstRoom[mustBeNull]} right after the first '
          'rematch request; docs/PROTOCOL.md section 16.2 item 1 requires '
          'it null',
        );
      }
    }
    final Object? rematchFieldRaw = firstRoom['rematch'];
    if (rematchFieldRaw is! Map<String, Object?>) {
      throw ScenarioFailure(
        'room.rematch is not an object after the first rematch request; '
        'got $rematchFieldRaw',
      );
    }
    final int by = requireInt(rematchFieldRaw, 'by', frame: 'room.rematch');
    if (by != firstRequester) {
      throw ScenarioFailure(
        'room.rematch.by=$by, expected the requesting seat $firstRequester',
      );
    }
    final List<int> readyAfterFirst =
        requireIntList(rematchFieldRaw, 'ready', frame: 'room.rematch');
    if (readyAfterFirst.length != 1 ||
        readyAfterFirst.first != firstRequester) {
      throw ScenarioFailure(
        'room.rematch.ready=$readyAfterFirst after only seat $firstRequester '
        'requested a rematch; expected [$firstRequester]',
      );
    }
    final String chainCommit2 =
        requireString(firstRoom, 'chain_commit', frame: 'room');
    final int chainIndex2 = requireInt(firstRoom, 'chain_index', frame: 'room');
    if (chainCommit2 == setup.chainCommit) {
      throw ScenarioFailure(
        'the rematch chain_commit ($chainCommit2) is identical to the '
        'first game\'s (${setup.chainCommit}); docs/PROTOCOL.md section '
        '16.2 item 2 requires a chain generated fresh for the new game',
      );
    }

    final List<int> remainingSeats =
        seatOrder.where((int s) => s != firstRequester).toList();
    for (int i = 0; i < remainingSeats.length; i++) {
      final int seatIndex = remainingSeats[i];
      final String acceptId = await setup.seats[seatIndex]!.socket
          .send('rematch', <String, Object?>{});
      for (final int otherSeat in seatOrder) {
        final SimSocket socket = setup.seats[otherSeat]!.socket;
        final Frame frame = await socket.next(timeout: perFrameTimeout);
        expectFrameType(frame, 'room',
            because: 'seat $seatIndex accepting the rematch '
                '(section 16.3), observed by seat $otherSeat');
        if (otherSeat == seatIndex) {
          final Object? re = frame['re'];
          if (re != acceptId) {
            throw ScenarioFailure(
              'seat $seatIndex\'s own reply to its rematch accept carried '
              're=$re, expected $acceptId',
            );
          }
        }
      }
    }

    // The last acceptance above completed `rematch.ready` for every seat
    // `setUpGame` occupied, all of them still connected (nothing in this
    // scenario drops a socket), so docs/PROTOCOL.md section 16.4's
    // "everyone accepted" auto-start must have fired immediately after that
    // last room broadcast. Every socket now has that start sequence queued;
    // only the observer's is read here; the others are drained later by
    // `assertReceivedGameOver` below, the same way `setUpGame`'s own opening
    // `turn` frame is left for `playGame` to consume on the observer and
    // left queued, unread, on every other socket.
    final Map<String, Object?> started2 = await _collectRematchStartFrames(
      observerSeat.socket,
      expectedServerSeeds: players,
      perFrameTimeout: perFrameTimeout,
    );
    final String gameId2 =
        requireString(started2, 'game_id', frame: 'game_started (rematch)');
    final String clientSeeds2 = requireString(started2, 'client_seeds',
        frame: 'game_started (rematch)');
    final int initialTurnSeat2 =
        requireInt(started2, 'turn', frame: 'game_started (rematch)');
    if (gameId2 == setup.gameId) {
      throw ScenarioFailure(
        'the rematch game_id ($gameId2) is identical to the first game\'s '
        '(${setup.gameId}); docs/PROTOCOL.md section 11.3 forbids reusing '
        'a chain, and therefore a game_id, across games',
      );
    }

    final FairnessTracker fairness2 = FairnessTracker(
      chainCommit: chainCommit2,
      gameId: gameId2,
      clientSeeds: clientSeeds2,
    );
    final PlayResult result2 = await playGame(
      observer: observerSeat.socket,
      seats: setup.seats,
      fairness: fairness2,
      initialTurnSeat: initialTurnSeat2,
      perFrameTimeout: perFrameTimeout,
    );
    for (final Seat seat in setup.seats.values) {
      if (identical(seat.socket, observerSeat.socket)) {
        continue;
      }
      await assertReceivedGameOver(
        seat.socket,
        result2.winner,
        expectedVerifyUrl: result2.verifyUrl,
      );
    }

    String detail = 'game 1: winner=seat ${result1.winner}, '
        '${result1.rollsVerified} rolls, game_id=${setup.gameId}, '
        'chain_commit=${setup.chainCommit}; rematch: chain_index=$chainIndex2; '
        'game 2: winner=seat ${result2.winner}, ${result2.rollsVerified} '
        'rolls, game_id=$gameId2, chain_commit=$chainCommit2; both games '
        'used distinct game_id and chain_commit, $players/$players clients '
        'confirmed both game_over frames';

    if (fetchRecord) {
      await fetchAndVerifyRecord(
        verifyUrl: result1.verifyUrl,
        gameId: setup.gameId,
        chainCommit: setup.chainCommit,
        clientSeeds: setup.clientSeeds,
        winner: result1.winner,
        rolls: result1.rolls,
      );
      await fetchAndVerifyRecord(
        verifyUrl: result2.verifyUrl,
        gameId: gameId2,
        chainCommit: chainCommit2,
        clientSeeds: clientSeeds2,
        winner: result2.winner,
        rolls: result2.rolls,
      );
      detail += ', both records fetched and matched '
          '(${result1.rolls.length} + ${result2.rolls.length} rolls)';
    }

    return ScenarioResult(name: name, passed: true, detail: detail);
  } catch (error) {
    return ScenarioResult(name: name, passed: false, detail: error.toString());
  } finally {
    for (final SimSocket socket in allSockets) {
      await socket.close();
    }
  }
}

/// Reads frames off [socket] until it has seen one `game_started` and
/// exactly [expectedServerSeeds] `seat_seed` frames, tolerating either
/// order between them -- the same contract as `game.dart`'s private
/// `_collectStartGameFrames`, duplicated here because that function is not
/// exported and this order's file list does not permit editing `game.dart`
/// to make it so. Every seed at a rematch's "everyone accepted" auto-start
/// is server-assigned (`origin: "server"`): nobody calls `set_seed` in this
/// scenario's rematch LOBBY, since every seat sends `rematch` as soon as
/// setup is done, with no pause in which a `set_seed` could be sent.
Future<Map<String, Object?>> _collectRematchStartFrames(
  SimSocket socket, {
  required int expectedServerSeeds,
  required Duration perFrameTimeout,
  int maxFrames = 32,
}) async {
  int serverSeedsSeen = 0;
  Map<String, Object?>? started;
  for (int i = 0; i < maxFrames; i++) {
    if (started != null && serverSeedsSeen >= expectedServerSeeds) {
      break;
    }
    final Frame frame = await socket.next(timeout: perFrameTimeout);
    final String type = frameType(frame);
    if (type == 'seat_seed') {
      final String origin =
          requireString(frameData(frame), 'origin', frame: 'seat_seed');
      if (origin != 'server') {
        throw ScenarioFailure(
          'rematch auto-start: unexpected seat_seed with origin "$origin"; '
          'no seat called set_seed in the rematch lobby, so every seed at '
          'this auto-start must be server-assigned (docs/PROTOCOL.md '
          'section 11.2)',
        );
      }
      serverSeedsSeen++;
    } else if (type == 'game_started') {
      started = frameData(frame);
    } else {
      throw ScenarioFailure(
        'rematch auto-start: expected only game_started or server-assigned '
        'seat_seed frames, got "$type": ${frameData(frame)}',
      );
    }
  }
  if (started == null) {
    throw ScenarioFailure(
      'rematch auto-start did not produce a game_started frame within '
      '$maxFrames frames',
    );
  }
  if (serverSeedsSeen != expectedServerSeeds) {
    throw ScenarioFailure(
      'rematch auto-start: expected $expectedServerSeeds server-assigned '
      'seat_seed frames, saw $serverSeedsSeen',
    );
  }
  return started;
}
