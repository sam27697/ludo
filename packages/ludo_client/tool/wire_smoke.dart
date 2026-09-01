// Order 106: the client wire smoke harness. Drives the client's own network
// stack -- RoomConnection, WsTransport, Frame and RoomSnapshot under
// lib/src/net/ -- through a complete game of Ludo against a real, deployed
// server over a real WebSocket. Nothing here is a fake or a mock: every
// connection is a real dart:io socket to the URL on the command line, and
// every legal move is one the server itself offered, per docs/PROTOCOL.md
// section 10. This tool never decides legality and never imports
// package:ludo_engine.
//
//   dart run tool/wire_smoke.dart --target wss://stg.ludo.provefair.app
//       [--scenario all|full-game|reconnect]
//       [--players N] [--timeout-seconds N]
//
// Modelled on packages/ludo_server/tool/simulator.dart: same PASS/FAIL/exit
// code convention, same overall-budget stopwatch loop. That simulator is a
// separate implementation -- it builds its own frames and opens its own
// sockets -- and proves the server. This file proves the client package that
// actually ships in the APK.
//
// A finding, not a workaround: docs/PROTOCOL.md's reconnect scenario asks
// for a socket that "drops without a clean close", explicitly distinct from
// close(), "the polite path". WireTransport's only termination primitive is
// close([int code]) (lib/src/net/transport.dart:57-63), and the one real
// implementation, WsTransport.close (lib/src/net/ws_transport.dart:118-129),
// always runs the ordinary WebSocket closing handshake -- it calls
// _finish() and then awaits channel.sink.close(code) -- whatever code is
// passed. There is no primitive on WireTransport, RoomConnection or
// WsTransport that abandons a socket without writing a Close control frame.
// (packages/ludo_server/tool/sim/game.dart:409-411, the reference
// simulator's own "hard drop", has the same limit: it too just calls
// close() on its raw socket.) The closest approximation reachable without
// touching lib/ is below: the reconnect scenario runs the seat that will be
// dropped inside its own spawned Isolate and calls Isolate.kill(priority:
// Isolate.immediate) on it. An immediate kill runs no further Dart code in
// that isolate -- no close(), no Close frame is ever written by this
// client -- and the OS reclaims the socket as an abrupt, unannounced
// disconnect rather than a negotiated shutdown. This cannot be verified
// from the client side (there is no way to inspect the TCP stream from
// here), but it is a materially different event from calling close() with
// any code, and it is offered as that: the closest thing achievable, not a
// claim of a raw TCP reset.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/ws_transport.dart';

Future<void> main(List<String> arguments) async {
  final WireSmokeArgs args;
  try {
    args = parseArgs(arguments);
  } on ArgsError catch (error) {
    stderr.writeln('wire_smoke: $error');
    stderr.write(usage);
    exitCode = 2;
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

    ScenarioResult result;
    try {
      final Future<ScenarioResult> run = scenarioName == 'full-game'
          ? runFullGame(args.target, args.players, timeout: remaining)
          : runReconnect(args.target, args.players, timeout: remaining);
      result = await run.timeout(remaining);
    } on TimeoutException {
      result = ScenarioResult(
        name: scenarioName,
        passed: false,
        detail:
            'did not finish within the overall --timeout-seconds '
            '${args.timeoutSeconds} budget (${stopwatch.elapsed.inSeconds}s '
            'elapsed when the budget ran out)',
      );
    } catch (error) {
      // A scenario function is expected to catch everything itself and
      // return a ScenarioResult; this is a last-resort net so a truly
      // unexpected failure still produces a FAIL line and a non-zero exit
      // rather than an uncaught exception and a stack trace.
      result = ScenarioResult(
        name: scenarioName,
        passed: false,
        detail:
            'unhandled exception outside the scenario\'s own error '
            'handling: ${describeError(error)}',
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

  print('wire_smoke: $passed passed, $failed failed');
  exitCode = failed == 0 ? 0 : 1;
}

// --- argument parsing ------------------------------------------------

/// The `--scenario` values this harness understands, in the order they run
/// under `all`.
const List<String> knownScenarios = <String>['full-game', 'reconnect'];

/// Thrown for any malformed invocation. main prints [message] to stderr and
/// exits 2 without attempting to connect anywhere.
class ArgsError implements Exception {
  ArgsError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The parsed, validated command line.
class WireSmokeArgs {
  WireSmokeArgs({
    required this.target,
    required this.scenario,
    required this.players,
    required this.timeoutSeconds,
  });

  /// The WebSocket URL of the server under test, ws:// or wss://, exactly as
  /// given on the command line.
  final Uri target;

  /// `all`, or one of [knownScenarios].
  final String scenario;

  /// Seats to play with, 2 to 4. Defaults to 4.
  final int players;

  /// Bounds each selected scenario, not the whole run. Defaults to 120.
  final int timeoutSeconds;

  /// The scenario names this run should execute, in a fixed order,
  /// regardless of whether `--scenario` named one of them or `all`.
  List<String> get selectedScenarios =>
      scenario == 'all' ? knownScenarios : <String>[scenario];
}

WireSmokeArgs parseArgs(List<String> arguments) {
  String? target;
  String scenario = 'all';
  int players = 4;
  int timeoutSeconds = 120;

  int i = 0;
  while (i < arguments.length) {
    final String arg = arguments[i];
    switch (arg) {
      case '--target':
        target = _valueAfter(arguments, i, arg);
        i += 2;
        break;
      case '--scenario':
        scenario = _valueAfter(arguments, i, arg);
        i += 2;
        break;
      case '--players':
        final String raw = _valueAfter(arguments, i, arg);
        final int? parsed = int.tryParse(raw);
        if (parsed == null) {
          throw ArgsError('--players must be an integer, got "$raw"');
        }
        players = parsed;
        i += 2;
        break;
      case '--timeout-seconds':
        final String raw = _valueAfter(arguments, i, arg);
        final int? parsed = int.tryParse(raw);
        if (parsed == null) {
          throw ArgsError('--timeout-seconds must be an integer, got "$raw"');
        }
        timeoutSeconds = parsed;
        i += 2;
        break;
      default:
        throw ArgsError('unrecognised argument: $arg');
    }
  }

  if (target == null) {
    throw ArgsError('--target is required');
  }
  final Uri parsedTarget;
  try {
    parsedTarget = Uri.parse(target);
  } on FormatException catch (error) {
    throw ArgsError('--target is not a valid URL ("$target"): $error');
  }
  if (parsedTarget.scheme != 'ws' && parsedTarget.scheme != 'wss') {
    throw ArgsError(
      '--target must be a ws:// or wss:// URL, got scheme '
      '"${parsedTarget.scheme}" ("$target")',
    );
  }

  if (scenario != 'all' && !knownScenarios.contains(scenario)) {
    throw ArgsError(
      '--scenario must be one of all, ${knownScenarios.join(", ")}; got '
      '"$scenario"',
    );
  }

  if (players < 2 || players > 4) {
    throw ArgsError('--players must be 2, 3 or 4, got $players');
  }

  if (timeoutSeconds <= 0) {
    throw ArgsError('--timeout-seconds must be positive, got $timeoutSeconds');
  }

  return WireSmokeArgs(
    target: parsedTarget,
    scenario: scenario,
    players: players,
    timeoutSeconds: timeoutSeconds,
  );
}

String _valueAfter(List<String> arguments, int i, String flag) {
  if (i + 1 >= arguments.length) {
    throw ArgsError('$flag requires a value');
  }
  return arguments[i + 1];
}

/// Printed to stderr alongside any [ArgsError].
const String usage = '''
usage: dart run tool/wire_smoke.dart --target <url> [--scenario all|full-game|reconnect] [--players N] [--timeout-seconds N]

  --target           required. Base WebSocket URL of a running server, ws:// or wss://.
  --scenario         default: all
  --players          default: 4. Seats to play with, 2 to 4.
  --timeout-seconds  default: 120. Bounds each selected scenario, not the whole run.
''';

// --- shared result type ------------------------------------------------

/// A readable rendering of an error this harness caught. `ProtocolErrorException`,
/// `RequestTimeoutException` and `ConnectionClosedException`
/// (lib/src/net/connection.dart) carry no `toString()` override of their
/// own, so the default `Instance of '...'` tells a reader nothing about
/// what actually went wrong; this pulls out the fields that matter for
/// each of them instead.
String describeError(Object error) {
  if (error is ProtocolErrorException) {
    return 'ProtocolErrorException(code=${error.code}, '
        'message=${error.message})';
  }
  if (error is RequestTimeoutException) {
    return 'RequestTimeoutException(type=${error.type})';
  }
  if (error is ConnectionClosedException) {
    return 'ConnectionClosedException';
  }
  return error.toString();
}

class ScenarioResult {
  const ScenarioResult({
    required this.name,
    required this.passed,
    required this.detail,
  });

  final String name;
  final bool passed;
  final String detail;
}

// --- the shared turn-taking agent --------------------------------------

/// Listens on [connection]'s own frame stream and, whenever the wire says
/// it is this connection's own seat's turn, acts on it: `roll` when a
/// `turn` frame names this seat, `move` with the first entry of `legal`
/// when a `rolled` frame names this seat and left a legal move pending.
///
/// This reads exactly the fields docs/PROTOCOL.md section 5 puts on
/// `rolled` -- `legal` is the list of token indices the server itself says
/// are legal for this roll -- and nothing here computes legality, a
/// capture or a winner on its own. Which entry of `legal` gets played is
/// arbitrary; the first one is picked only so the choice is deterministic
/// and reproducible, never because it is believed to be a better move than
/// any other legal one.
///
/// Every failure this agent can observe -- a rejected roll or move, or an
/// error frame this connection never asked for -- is reported through
/// [reportError] rather than thrown, because it fires from inside a stream
/// listener with no caller left on the stack to catch it.
void attachAgent(
  RoomConnection connection,
  void Function(Object error) reportError,
) {
  connection.frames.listen((Frame frame) {
    final int? seat = connection.seat;
    if (seat == null) {
      return;
    }
    switch (frame.type) {
      case 'turn':
        if (frame.data['seat'] == seat) {
          connection.roll().then<void>(
            (Frame reply) {},
            onError: (Object error) {
              reportError(error);
            },
          );
        }
        break;
      case 'rolled':
        if (frame.data['seat'] != seat) {
          break;
        }
        final Object? legalRaw = frame.data['legal'];
        if (legalRaw is! List) {
          reportError(
            StateError(
              'rolled frame for our own seat $seat carried no legal list: '
              '${frame.data}',
            ),
          );
          break;
        }
        final List<int> legal = legalRaw.whereType<int>().toList();
        if (legal.isEmpty) {
          // Empty means the turn is about to pass on its own; nothing to
          // play, docs/PROTOCOL.md section 5.
          break;
        }
        connection
            .move(legal.first)
            .then<void>(
              (Frame reply) {},
              onError: (Object error) {
                reportError(error);
              },
            );
        break;
      case 'error':
        if (frame.re == null) {
          reportError(
            StateError(
              'unsolicited error frame on seat $seat: '
              'code=${frame.data['code']} message=${frame.data['message']}',
            ),
          );
        }
        break;
    }
  });
}

/// Verifies the pass condition every scenario shares: the room reached
/// FINISHED with [winner] as its winner, and that seat's four tokens are
/// all at progress 57 -- home, docs/RULES.md section 1.2 -- in [snapshot].
void checkWinnerHome(RoomSnapshot snapshot, int winner, String scenarioName) {
  if (snapshot.state != RoomState.finished) {
    throw StateError(
      '$scenarioName: final snapshot state is ${snapshot.state}, expected '
      'RoomState.finished',
    );
  }
  if (snapshot.winner != winner) {
    throw StateError(
      '$scenarioName: final snapshot winner is ${snapshot.winner}, expected '
      'seat $winner from the game_over frame already observed',
    );
  }
  SeatState? winnerSeat;
  for (final SeatState seat in snapshot.seats) {
    if (seat.seat == winner) {
      winnerSeat = seat;
      break;
    }
  }
  if (winnerSeat == null) {
    throw StateError(
      '$scenarioName: final snapshot has no seat entry for winner $winner',
    );
  }
  if (winnerSeat.tokens.length != 4 ||
      winnerSeat.tokens.any((int progress) => progress != 57)) {
    throw StateError(
      '$scenarioName: winner seat $winner tokens are ${winnerSeat.tokens}, '
      'expected all four at progress 57 (home), docs/RULES.md section 1.2',
    );
  }
}

// --- scenario full-game -------------------------------------------------

Future<ScenarioResult> runFullGame(
  Uri target,
  int players, {
  required Duration timeout,
}) async {
  const String name = 'full-game';
  final List<RoomConnection> connections = <RoomConnection>[];
  final Set<RoomConnection> intentionalCloses = <RoomConnection>{};
  final Completer<Object> errorCompleter = Completer<Object>();
  void reportError(Object error) {
    if (!errorCompleter.isCompleted) {
      errorCompleter.complete(error);
    }
  }

  Future<RoomConnection> open(String label) async {
    final RoomConnection connection = RoomConnection(
      url: target,
      connect: connectWsTransport,
    );
    connections.add(connection);
    await connection.open();
    connection.done.then((_) {
      if (!intentionalCloses.contains(connection)) {
        reportError(
          StateError('$label: socket closed without this harness closing it'),
        );
      }
    });
    return connection;
  }

  final Stopwatch stopwatch = Stopwatch()..start();
  try {
    return await _playFullGame(
      players: players,
      open: open,
      reportError: reportError,
      errorCompleter: errorCompleter,
      stopwatch: stopwatch,
    ).timeout(timeout);
  } on TimeoutException {
    return ScenarioResult(
      name: name,
      passed: false,
      detail:
          'did not reach a winner within --timeout-seconds '
          '${timeout.inSeconds}s (players=$players, '
          '${stopwatch.elapsed.inSeconds}s elapsed)',
    );
  } catch (error) {
    return ScenarioResult(
      name: name,
      passed: false,
      detail: describeError(error),
    );
  } finally {
    for (final RoomConnection connection in connections) {
      intentionalCloses.add(connection);
      await connection.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }
  }
}

Future<ScenarioResult> _playFullGame({
  required int players,
  required Future<RoomConnection> Function(String label) open,
  required void Function(Object error) reportError,
  required Completer<Object> errorCompleter,
  required Stopwatch stopwatch,
}) async {
  const String name = 'full-game';

  final RoomConnection host = await open('host');
  final RoomSnapshot created = await host.createRoom(
    name: 'wire-smoke-host',
    players: players,
  );
  final String code = created.code;
  attachAgent(host, reportError);

  for (int i = 1; i < players; i++) {
    final RoomConnection guest = await open('guest-$i');
    await guest.joinRoom(code: code, name: 'wire-smoke-guest-$i');
    attachAgent(guest, reportError);
  }

  int rolls = 0;
  int moves = 0;
  int turns = 0;
  final Completer<int> winnerCompleter = Completer<int>();
  host.frames.listen((Frame frame) {
    switch (frame.type) {
      case 'turn':
        turns++;
        break;
      case 'rolled':
        rolls++;
        break;
      case 'moved':
        moves++;
        break;
      case 'game_over':
        final Object? winner = frame.data['winner'];
        if (winner is int && !winnerCompleter.isCompleted) {
          winnerCompleter.complete(winner);
        }
        break;
    }
  });

  await host.startGame();

  final Object outcome = await Future.any<Object>(<Future<Object>>[
    winnerCompleter.future,
    errorCompleter.future,
  ]);
  if (outcome is! int) {
    throw outcome;
  }
  final int winner = outcome;

  // host.seatToken is guaranteed set here: create_room's own seat_assigned
  // arrived on this socket before the room reply that resolved createRoom
  // above, and RoomConnection captures it synchronously off that frame.
  final RoomSnapshot finalSnapshot = await host.resume(
    code: code,
    seatToken: host.seatToken!,
  );
  checkWinnerHome(finalSnapshot, winner, name);

  stopwatch.stop();
  final double elapsedSeconds = stopwatch.elapsedMilliseconds / 1000;
  return ScenarioResult(
    name: name,
    passed: true,
    detail:
        'code=$code winner=seat $winner players=$players turns=$turns '
        'rolls=$rolls moves=$moves '
        'elapsed=${elapsedSeconds.toStringAsFixed(2)}s',
  );
}

// --- scenario reconnect --------------------------------------------------

/// Sent to the isolate that owns the connection which will be dropped
/// rudely, at spawn time.
class _DropPlayerRequest {
  const _DropPlayerRequest({
    required this.target,
    required this.code,
    required this.name,
    required this.replyPort,
  });

  final String target;
  final String code;
  final String name;
  final SendPort replyPort;
}

/// A sentinel distinct from any real value a scenario waits on, used to
/// tell "the awaited signal fired" apart from "an error fired instead" when
/// Future.any races the two and the signal itself carries no payload.
const Object _firstMoveSignal = Object();

/// Entry point of the isolate that owns the one connection the reconnect
/// scenario drops rudely. Everything this seat needs to do before the drop
/// -- join, and play its own turns via [attachAgent] -- runs here, entirely
/// isolated from the connections the parent isolate owns directly. See the
/// file header for why this is the mechanism: Isolate.kill(priority:
/// Isolate.immediate) on this isolate runs no further code in it, so
/// nothing here ever calls close() or writes a WebSocket Close frame.
Future<void> _dropPlayerIsolateMain(_DropPlayerRequest request) async {
  final RoomConnection connection = RoomConnection(
    url: Uri.parse(request.target),
    connect: connectWsTransport,
  );
  void reportError(Object error) {
    request.replyPort.send(<String, Object?>{
      'kind': 'error',
      'message': describeError(error),
    });
  }

  try {
    await connection.open();
    attachAgent(connection, reportError);
    await connection.joinRoom(code: request.code, name: request.name);
    final int? seat = connection.seat;
    final String? seatToken = connection.seatToken;
    if (seat == null || seatToken == null) {
      reportError(
        StateError(
          'joinRoom completed without a captured seat/seat token '
          '(seat=$seat, seatToken=${seatToken == null ? 'null' : 'set'})',
        ),
      );
      return;
    }
    request.replyPort.send(<String, Object?>{
      'kind': 'joined',
      'seat': seat,
      'seatToken': seatToken,
    });
    // Stay alive and keep playing this seat's own turns, via the listener
    // attachAgent already registered above, until the parent isolate kills
    // this one outright. This await never completes on its own; nothing
    // here polls anything.
    await Completer<void>().future;
  } catch (error) {
    reportError(error);
  }
}

Future<ScenarioResult> runReconnect(
  Uri target,
  int players, {
  required Duration timeout,
}) async {
  const String name = 'reconnect';
  final List<RoomConnection> connections = <RoomConnection>[];
  final Set<RoomConnection> intentionalCloses = <RoomConnection>{};
  final Completer<Object> errorCompleter = Completer<Object>();
  void reportError(Object error) {
    if (!errorCompleter.isCompleted) {
      errorCompleter.complete(error);
    }
  }

  Future<RoomConnection> open(String label) async {
    final RoomConnection connection = RoomConnection(
      url: target,
      connect: connectWsTransport,
    );
    connections.add(connection);
    await connection.open();
    connection.done.then((_) {
      if (!intentionalCloses.contains(connection)) {
        reportError(
          StateError('$label: socket closed without this harness closing it'),
        );
      }
    });
    return connection;
  }

  Isolate? dropIsolate;
  ReceivePort? dropPort;
  final Stopwatch stopwatch = Stopwatch()..start();

  try {
    return await _playReconnect(
      target: target,
      players: players,
      open: open,
      reportError: reportError,
      errorCompleter: errorCompleter,
      stopwatch: stopwatch,
      registerIsolate: (Isolate isolate, ReceivePort port) {
        dropIsolate = isolate;
        dropPort = port;
      },
    ).timeout(timeout);
  } on TimeoutException {
    return ScenarioResult(
      name: name,
      passed: false,
      detail:
          'did not reach a winner within --timeout-seconds '
          '${timeout.inSeconds}s (players=$players, '
          '${stopwatch.elapsed.inSeconds}s elapsed)',
    );
  } catch (error) {
    return ScenarioResult(
      name: name,
      passed: false,
      detail: describeError(error),
    );
  } finally {
    dropIsolate?.kill(priority: Isolate.immediate);
    dropPort?.close();
    for (final RoomConnection connection in connections) {
      intentionalCloses.add(connection);
      await connection.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }
  }
}

Future<ScenarioResult> _playReconnect({
  required Uri target,
  required int players,
  required Future<RoomConnection> Function(String label) open,
  required void Function(Object error) reportError,
  required Completer<Object> errorCompleter,
  required Stopwatch stopwatch,
  required void Function(Isolate isolate, ReceivePort port) registerIsolate,
}) async {
  const String name = 'reconnect';

  final RoomConnection host = await open('host');
  final RoomSnapshot created = await host.createRoom(
    name: 'wire-smoke-host',
    players: players,
  );
  final String code = created.code;
  attachAgent(host, reportError);

  for (int i = 2; i < players; i++) {
    final RoomConnection guest = await open('guest-$i');
    await guest.joinRoom(code: code, name: 'wire-smoke-guest-$i');
    attachAgent(guest, reportError);
  }

  // The one non-host seat that gets dropped rudely lives in its own
  // isolate for its whole life up to the drop -- see the file header.
  final ReceivePort dropPort = ReceivePort();
  final Completer<Map<Object?, Object?>> joinedCompleter =
      Completer<Map<Object?, Object?>>();
  bool killedDeliberately = false;
  dropPort.listen((Object? message) {
    if (message == null) {
      // Isolate.spawn's onExit contract: null unless this isolate ended on
      // its own, which before the deliberate kill is a defect worth
      // reporting rather than a silent hang.
      if (!killedDeliberately) {
        reportError(
          StateError(
            'drop-seat isolate exited on its own before the deliberate kill',
          ),
        );
      }
      return;
    }
    if (message is List<Object?>) {
      // Isolate.spawn's onError contract: [errorDescription, stackDescription].
      reportError(StateError('drop-seat isolate uncaught error: $message'));
      return;
    }
    if (message is Map<Object?, Object?>) {
      final Object? kind = message['kind'];
      if (kind == 'joined' && !joinedCompleter.isCompleted) {
        joinedCompleter.complete(message);
      } else if (kind == 'error') {
        reportError(StateError('drop-seat isolate: ${message['message']}'));
      }
    }
  });

  final Isolate dropIsolate = await Isolate.spawn<_DropPlayerRequest>(
    _dropPlayerIsolateMain,
    _DropPlayerRequest(
      target: target.toString(),
      code: code,
      name: 'wire-smoke-drop',
      replyPort: dropPort.sendPort,
    ),
    onError: dropPort.sendPort,
    onExit: dropPort.sendPort,
  );
  registerIsolate(dropIsolate, dropPort);

  final Object joinedOutcome = await Future.any<Object>(<Future<Object>>[
    joinedCompleter.future,
    errorCompleter.future,
  ]);
  if (joinedOutcome is! Map<Object?, Object?>) {
    throw joinedOutcome;
  }
  final int dropSeat = joinedOutcome['seat']! as int;
  final String dropSeatToken = joinedOutcome['seatToken']! as String;

  await host.startGame();

  int rolls = 0;
  int moves = 0;
  int turns = 0;
  final Completer<void> firstMoveCompleter = Completer<void>();
  final Completer<int> winnerCompleter = Completer<int>();
  host.frames.listen((Frame frame) {
    switch (frame.type) {
      case 'turn':
        turns++;
        break;
      case 'rolled':
        rolls++;
        break;
      case 'moved':
        moves++;
        if (!firstMoveCompleter.isCompleted) {
          firstMoveCompleter.complete();
        }
        break;
      case 'game_over':
        final Object? winner = frame.data['winner'];
        if (winner is int && !winnerCompleter.isCompleted) {
          winnerCompleter.complete(winner);
        }
        break;
    }
  });

  final Object firstMoveOutcome = await Future.any<Object>(<Future<Object>>[
    firstMoveCompleter.future.then((_) => _firstMoveSignal),
    errorCompleter.future,
  ]);
  if (!identical(firstMoveOutcome, _firstMoveSignal)) {
    throw firstMoveOutcome;
  }
  if (winnerCompleter.isCompleted) {
    // game_over is only ever published right after the moved frame for the
    // winning move (packages/ludo_server/lib/src/connection.dart's
    // _publishMove sends moved, then game_over, on the same socket in that
    // order), so this should be unreachable; guarded rather than assumed.
    throw StateError(
      'the game reached game_over before the first move was ever observed '
      'on this harness\'s own frame stream; either a protocol defect or a '
      'bug in this harness\'s frame ordering assumption',
    );
  }

  killedDeliberately = true;
  dropIsolate.kill(priority: Isolate.immediate);

  final RoomConnection resumed = await open('resumed-seat-$dropSeat');
  final RoomSnapshot resumedSnapshot = await resumed.resume(
    code: code,
    seatToken: dropSeatToken,
  );
  if (resumedSnapshot.state == RoomState.lobby) {
    throw StateError(
      'resume() returned a LOBBY snapshot for seat $dropSeat; expected the '
      'game already in progress',
    );
  }
  if (resumed.seat != dropSeat) {
    throw StateError(
      'resume() put this socket in seat ${resumed.seat}, expected the '
      'dropped seat $dropSeat back',
    );
  }
  attachAgent(resumed, reportError);

  final Object outcome = await Future.any<Object>(<Future<Object>>[
    winnerCompleter.future,
    errorCompleter.future,
  ]);
  if (outcome is! int) {
    throw outcome;
  }
  final int winner = outcome;

  final RoomSnapshot finalSnapshot = await resumed.resume(
    code: code,
    seatToken: dropSeatToken,
  );
  checkWinnerHome(finalSnapshot, winner, name);

  stopwatch.stop();
  final double elapsedSeconds = stopwatch.elapsedMilliseconds / 1000;
  return ScenarioResult(
    name: name,
    passed: true,
    detail:
        'code=$code winner=seat $winner players=$players '
        'dropped_seat=$dropSeat turns=$turns rolls=$rolls moves=$moves '
        'elapsed=${elapsedSeconds.toStringAsFixed(2)}s; seat $dropSeat was '
        'killed via its own isolate (no close() ever called on that '
        'connection), resumed with its seat_token, and played its '
        'remaining turns over the new socket',
  );
}
