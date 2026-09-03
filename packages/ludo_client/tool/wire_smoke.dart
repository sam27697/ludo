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
//       [--players N] [--timeout-seconds N] [--pace-ms N]
//       [--resume-grace-seconds N]
//
// Modelled on packages/ludo_server/tool/simulator.dart: same PASS/FAIL/exit
// code convention, same overall-budget stopwatch loop. That simulator is a
// separate implementation -- it builds its own frames and opens its own
// sockets -- and proves the server. This file proves the client package that
// actually ships in the APK.
//
// Every message this harness itself sends on a connection is paced against
// that same connection's own last send, --pace-ms apart (default 120ms, see
// the Paced class below). docs/PROTOCOL.md section 7 limits any one
// connection to 30 messages/second before RATE_LIMITED and a close at 60
// (connection.dart:193, rate_limit.dart), and a seat that rolls a six or
// captures keeps the turn, so an unpaced harness fires roll/move pairs back
// to back with no gap at all and crosses that ceiling on its own -- server
// behaviour that is correct and not a client defect, but not a fair test of
// resume() either if it kills the very connection the test is driving.
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
          ? runFullGame(
              args.target,
              args.players,
              timeout: remaining,
              paceMs: args.paceMs,
            )
          : runReconnect(
              args.target,
              args.players,
              timeout: remaining,
              paceMs: args.paceMs,
              resumeGraceSeconds: args.resumeGraceSeconds,
            );
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
    required this.paceMs,
    required this.resumeGraceSeconds,
  });

  /// The WebSocket URL of the server under test, ws:// or wss://, exactly as
  /// given on the command line.
  final Uri target;

  /// `all`, or one of [knownScenarios].
  final String scenario;

  /// Seats to play with, 2 to 4. Defaults to 4.
  final int players;

  /// Bounds each selected scenario, not the whole run. Defaults to 240 --
  /// with the D1 pacing below a full game is seconds rather than
  /// milliseconds, and staging also pays real round-trip latency on top.
  final int timeoutSeconds;

  /// Minimum milliseconds between two consecutive messages this harness
  /// sends on the same connection (D1), so no single connection can cross
  /// the server's per-connection ceiling of 30 messages/second
  /// (docs/PROTOCOL.md section 7, rate_limit.dart). Defaults to 120, which
  /// caps one connection at about 8 messages a second. 0 disables pacing.
  final int paceMs;

  /// How long, in seconds, the `reconnect` scenario's watchdog waits after
  /// the resumed connection's agent is attached before treating a send
  /// count still stuck at its baseline as a failure. Defaults to 90 --
  /// deliberately generous: the other seats are paced at --pace-ms apart so
  /// the resumed seat's own turn ordinarily comes back around within a few
  /// seconds of the resume, and the server's own turn timer is 45s, so 90s
  /// is two full timer periods. Unused by full-game.
  final int resumeGraceSeconds;

  /// The scenario names this run should execute, in a fixed order,
  /// regardless of whether `--scenario` named one of them or `all`.
  List<String> get selectedScenarios =>
      scenario == 'all' ? knownScenarios : <String>[scenario];
}

WireSmokeArgs parseArgs(List<String> arguments) {
  String? target;
  String scenario = 'all';
  int players = 4;
  int timeoutSeconds = 240;
  int paceMs = 120;
  int resumeGraceSeconds = 90;

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
      case '--pace-ms':
        final String raw = _valueAfter(arguments, i, arg);
        final int? parsed = int.tryParse(raw);
        if (parsed == null) {
          throw ArgsError('--pace-ms must be an integer, got "$raw"');
        }
        paceMs = parsed;
        i += 2;
        break;
      case '--resume-grace-seconds':
        final String raw = _valueAfter(arguments, i, arg);
        final int? parsed = int.tryParse(raw);
        if (parsed == null) {
          throw ArgsError(
            '--resume-grace-seconds must be an integer, got "$raw"',
          );
        }
        resumeGraceSeconds = parsed;
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

  if (paceMs < 0) {
    throw ArgsError('--pace-ms must not be negative, got $paceMs');
  }

  if (resumeGraceSeconds <= 0) {
    throw ArgsError(
      '--resume-grace-seconds must be positive, got $resumeGraceSeconds',
    );
  }

  return WireSmokeArgs(
    target: parsedTarget,
    scenario: scenario,
    players: players,
    timeoutSeconds: timeoutSeconds,
    paceMs: paceMs,
    resumeGraceSeconds: resumeGraceSeconds,
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
usage: dart run tool/wire_smoke.dart --target <url> [--scenario all|full-game|reconnect] [--players N] [--timeout-seconds N] [--pace-ms N] [--resume-grace-seconds N]

  --target                required. Base WebSocket URL of a running server, ws:// or wss://.
  --scenario              default: all
  --players               default: 4. Seats to play with, 2 to 4.
  --timeout-seconds       default: 240. Bounds each selected scenario, not the whole run.
  --pace-ms               default: 120. Minimum ms between two messages this harness sends on the same connection. 0 disables pacing.
  --resume-grace-seconds  default: 90. reconnect only: how long the resumed connection's watchdog waits for that connection to send anything before failing on its own, instead of waiting on the server's turn timer.
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

// --- per-connection pacing (D1) -----------------------------------------

/// Enforces the per-connection message pacing D1 requires: a minimum
/// interval between two consecutive messages this harness sends on **the
/// same** connection, so one seat rolling and moving back to back cannot
/// cross the server's per-connection ceiling of 30 messages/second
/// (docs/PROTOCOL.md section 7; connection.dart:193 calls
/// `rateLimiter.recordMessage(this)` on every envelope, and rate_limit.dart
/// keys that limiter by the connection object with a one-second sliding
/// window). One [Paced] instance belongs to exactly one connection and is
/// never shared, so four connections each sending in the same millisecond
/// do not wait on each other.
///
/// The wait is measured from the moment the *previous* message was sent on
/// this connection, not from when its reply arrived -- [send] stamps
/// [_lastSentAt] immediately before invoking [action], so real round-trip
/// latency to the server counts toward the interval instead of stacking on
/// top of it.
class Paced {
  Paced(this.paceMs);

  /// Minimum milliseconds between two sends on this connection. 0 disables
  /// pacing.
  final int paceMs;

  DateTime? _lastSentAt;

  /// How many times [send] has run [action] on this instance so far.
  /// Incremented once per call, after the pacing wait and right before
  /// [action] itself runs, so it counts messages actually sent rather than
  /// calls merely queued. A caller can snapshot this before some point in a
  /// connection's life and subtract later to learn how many messages that
  /// connection sent after that point -- the reconnect scenario uses this to
  /// assert the resumed connection actually sent something rather than
  /// merely reaching a winner while silent.
  int _sendCount = 0;

  /// The current value of the send counter described on [_sendCount].
  int get sendCount => _sendCount;

  Future<T> send<T>(Future<T> Function() action) async {
    if (paceMs > 0) {
      final DateTime? last = _lastSentAt;
      if (last != null) {
        final Duration interval = Duration(milliseconds: paceMs);
        final Duration sinceLast = DateTime.now().difference(last);
        if (sinceLast < interval) {
          await Future<void>.delayed(interval - sinceLast);
        }
      }
    }
    _lastSentAt = DateTime.now();
    _sendCount++;
    return action();
  }
}

// --- the shared turn-taking agent --------------------------------------

/// Listens on [connection]'s own frame stream and, whenever the wire says
/// it is this connection's own seat's turn, acts on it: `roll` when a
/// `turn` frame names this seat, `move` with the first entry of `legal`
/// when a `rolled` frame names this seat and left a legal move pending.
/// Both sends go through [paced], which must be the same [Paced] instance
/// every other message on [connection] (join_room, resume, start_game) is
/// sent through, so the D1 pacing interval is enforced against this
/// connection's whole message history and not just the agent's own sends.
///
/// This reads exactly the fields docs/PROTOCOL.md section 5 puts on
/// `rolled` -- `legal` is the list of token indices the server itself says
/// are legal for this roll -- and nothing here computes legality, a
/// capture or a winner on its own. Which entry of `legal` gets played is
/// arbitrary; the first one is picked only so the choice is deterministic
/// and reproducible, never because it is believed to be a better move than
/// any other legal one.
///
/// [seatOverride], a finding: [RoomConnection.seat] is set only from the
/// wire's `seat_assigned` frame (connection.dart:109-116, 208-216, set
/// alongside [RoomConnection.seatToken], which the interface this order
/// pins says is itself "captured from create_room/join_room replies").
/// `resume()` (connection.dart:303-312) never triggers a `seat_assigned`
/// -- the server's own `_handleResume`
/// (packages/ludo_server/lib/src/connection.dart:371-438) only ever sends
/// `room` and, on a real reconnect, a `presence` broadcast to *other*
/// sockets (`exceptConn: this`, line 419), unlike `_handleCreateRoom` and
/// `_handleJoinRoom` (same file, lines 299-303 and 349), which always send
/// `seat_assigned` on their own socket. So a fresh [RoomConnection] that
/// only ever calls [RoomConnection.resume] never learns its own seat
/// through [RoomConnection.seat] -- it stays null for that instance's
/// whole life. A real app gating its own turn-taking on
/// [RoomConnection.seat], the way this agent naturally would, would resume
/// into a snapshot that looks right and then never act again -- exactly
/// the failure mode the reconnect scenario exists to catch. The seat a
/// resumed connection is playing is knowable regardless, the same way a
/// real app already knows it: cached from the `seat_assigned` this same
/// logical player received at `join_room`, before the drop, and carried
/// forward across the new socket. [seatOverride] is that cached value; when
/// given, it takes the place of [RoomConnection.seat] here rather than
/// waiting on a frame that is never coming.
///
/// Every failure this agent can observe -- a rejected roll or move, or an
/// error frame this connection never asked for -- is reported through
/// [reportError] rather than thrown, because it fires from inside a stream
/// listener with no caller left on the stack to catch it.
void attachAgent(
  RoomConnection connection,
  Paced paced,
  void Function(Object error) reportError, {
  int? seatOverride,
}) {
  connection.frames.listen((Frame frame) {
    final int? seat = seatOverride ?? connection.seat;
    if (seat == null) {
      return;
    }
    switch (frame.type) {
      case 'turn':
        if (frame.data['seat'] == seat) {
          paced
              .send(connection.roll)
              .then<void>(
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
        paced
            .send(() => connection.move(legal.first))
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
  required int paceMs,
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
      paceMs: paceMs,
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
  required int paceMs,
}) async {
  const String name = 'full-game';

  final RoomConnection host = await open('host');
  final Paced hostPaced = Paced(paceMs);
  final RoomSnapshot created = await hostPaced.send(
    () => host.createRoom(name: 'wire-smoke-host', players: players),
  );
  final String code = created.code;
  attachAgent(host, hostPaced, reportError);

  for (int i = 1; i < players; i++) {
    final RoomConnection guest = await open('guest-$i');
    final Paced guestPaced = Paced(paceMs);
    await guestPaced.send(
      () => guest.joinRoom(code: code, name: 'wire-smoke-guest-$i'),
    );
    attachAgent(guest, guestPaced, reportError);
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

  await hostPaced.send(host.startGame);

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
  final RoomSnapshot finalSnapshot = await hostPaced.send(
    () => host.resume(code: code, seatToken: host.seatToken!),
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
    required this.paceMs,
  });

  final String target;
  final String code;
  final String name;
  final SendPort replyPort;

  /// D1's per-connection pacing, applied inside this isolate exactly as it
  /// is applied to every other connection in this harness -- this isolate
  /// runs on a fresh, independent [Paced] instance of its own, since Paced
  /// state cannot cross an isolate boundary.
  final int paceMs;
}

/// A sentinel distinct from any real value a scenario waits on, used to
/// tell "the awaited signal fired" apart from "an error fired instead" when
/// Future.any races the two and the signal itself carries no payload.
const Object _firstMoveSignal = Object();

/// The join name for the one seat the reconnect scenario drops and resumes.
/// A single constant so the name used to join and the name checked against
/// the resumed snapshot (see the resume identity check in `_playReconnect`)
/// cannot drift apart.
const String _dropPlayerName = 'wire-smoke-drop';

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

  final Paced paced = Paced(request.paceMs);
  try {
    await connection.open();
    attachAgent(connection, paced, reportError);
    await paced.send(
      () => connection.joinRoom(code: request.code, name: request.name),
    );
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
  required int paceMs,
  int resumeGraceSeconds = 90,
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
      paceMs: paceMs,
      resumeGraceSeconds: resumeGraceSeconds,
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
  required int paceMs,
  required int resumeGraceSeconds,
  required void Function(Isolate isolate, ReceivePort port) registerIsolate,
}) async {
  const String name = 'reconnect';

  final RoomConnection host = await open('host');
  final Paced hostPaced = Paced(paceMs);
  final RoomSnapshot created = await hostPaced.send(
    () => host.createRoom(name: 'wire-smoke-host', players: players),
  );
  final String code = created.code;
  attachAgent(host, hostPaced, reportError);

  for (int i = 2; i < players; i++) {
    final RoomConnection guest = await open('guest-$i');
    final Paced guestPaced = Paced(paceMs);
    await guestPaced.send(
      () => guest.joinRoom(code: code, name: 'wire-smoke-guest-$i'),
    );
    attachAgent(guest, guestPaced, reportError);
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
      name: _dropPlayerName,
      replyPort: dropPort.sendPort,
      paceMs: paceMs,
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

  await hostPaced.send(host.startGame);

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
  final Paced resumedPaced = Paced(paceMs);
  final RoomSnapshot resumedSnapshot = await resumedPaced.send(
    () => resumed.resume(code: code, seatToken: dropSeatToken),
  );
  if (resumedSnapshot.state == RoomState.lobby) {
    throw StateError(
      'resume() returned a LOBBY snapshot for seat $dropSeat; expected the '
      'game already in progress',
    );
  }
  // resumed.seat cannot confirm this identity: see the finding on
  // attachAgent's seatOverride parameter above -- resume() never triggers a
  // seat_assigned frame, so a fresh RoomConnection's own seat getter stays
  // null for its whole life even after a resume that genuinely succeeded.
  // What resume()'s reply does carry is the room's own seat list, so the
  // check goes there instead: the entry at dropSeat must still be the seat
  // this harness originally joined as _dropPlayerName, and it must show
  // connected again. docs/PROTOCOL.md section 13.2 and
  // packages/ludo_server/lib/src/connection.dart:414-421 both say presence
  // (and, on the server's own model, the seat's connected flag) only flips
  // when a resume actually reattaches a seat that was disconnected -- so a
  // connected seat by that name at that index is real, observable proof
  // this seat_token resumed seat dropSeat, not merely a snapshot that
  // happens to look right.
  SeatState? resumedSeatEntry;
  for (final SeatState seat in resumedSnapshot.seats) {
    if (seat.seat == dropSeat) {
      resumedSeatEntry = seat;
      break;
    }
  }
  if (resumedSeatEntry == null) {
    throw StateError(
      'resume() snapshot has no seat entry for seat $dropSeat at all: '
      '${resumedSnapshot.seats}',
    );
  }
  if (resumedSeatEntry.name != _dropPlayerName) {
    throw StateError(
      'resume() snapshot seat $dropSeat is named "${resumedSeatEntry.name}", '
      'expected "$_dropPlayerName"; this socket may have resumed the wrong '
      'seat',
    );
  }
  if (!resumedSeatEntry.connected) {
    throw StateError(
      'resume() snapshot seat $dropSeat still shows connected=false after '
      'the resume; docs/PROTOCOL.md section 13.2 says a resume that '
      'actually reattached the seat must flip this',
    );
  }
  // seatOverride: dropSeat, not the connection's own (null) seat getter --
  // see attachAgent's doc comment for why. A real app resuming after a
  // drop already knows its own seat from before the drop, the same way
  // this harness does.
  attachAgent(resumed, resumedPaced, reportError, seatOverride: dropSeat);
  // Baseline taken right after the agent is attached, so every send it goes
  // on to make -- and only those -- count toward the claim below. Nothing
  // between here and the winner outcome sends on resumedPaced.
  final int resumedSendsBaseline = resumedPaced.sendCount;

  // A watchdog that runs concurrently with the race below, not after it: the
  // server's own 45-second turn timer auto-plays a silent seat, so a
  // resumed connection that reattaches and then never speaks again still
  // lets the game reach a winner -- just slowly, about 45s per turn this
  // seat holds. Waiting for the winner and then checking the count
  // afterward (as this scenario used to) only catches that on a timeout an
  // hour later, if at all. This fires instead, on its own, once
  // --resume-grace-seconds has passed with the count still parked on its
  // baseline, while the game is still being played.
  final Completer<Object> resumeWatchdogCompleter = Completer<Object>();
  final Timer resumeWatchdogTimer = Timer(
    Duration(seconds: resumeGraceSeconds),
    () {
      if (!resumeWatchdogCompleter.isCompleted) {
        resumeWatchdogCompleter.complete(
          StateError(
            'reconnect: resumed connection for seat $dropSeat sent no '
            'message in the $resumeGraceSeconds second '
            '--resume-grace-seconds grace period after its agent was '
            'attached (send count is still ${resumedPaced.sendCount}, '
            'unchanged from its baseline of $resumedSendsBaseline); '
            "without this watchdog the server's own 45-second turn timer "
            'would auto-play this silent seat and hide the same defect '
            'behind an eventual winner instead of naming it here',
          ),
        );
      }
    },
  );

  final Object outcome;
  try {
    outcome = await Future.any<Object>(<Future<Object>>[
      winnerCompleter.future,
      errorCompleter.future,
      resumeWatchdogCompleter.future,
    ]);
  } finally {
    resumeWatchdogTimer.cancel();
  }
  if (outcome is! int) {
    throw outcome;
  }
  final int winner = outcome;

  // Read before the final resume() below, deliberately: that resume also
  // goes through resumedPaced.send and would otherwise inflate this count
  // by one even for a seat that reattached and then never acted again --
  // exactly the gap this order exists to close.
  final int resumedSendsAfterAttach =
      resumedPaced.sendCount - resumedSendsBaseline;
  if (resumedSendsAfterAttach <= 0) {
    // Unreachable in practice: the watchdog above already fails faster than
    // this for a seat that never sends. Kept as a second, independent guard
    // rather than removed, in case a future change alters what the
    // watchdog races against.
    throw StateError(
      'reconnect: resumed connection for seat $dropSeat sent '
      '$resumedSendsAfterAttach message(s) after its agent was attached and '
      'before the game reached a winner; expected at least one roll or '
      'move over the new socket, not merely a silent seat auto-played by '
      "the server's own turn timer",
    );
  }

  final RoomSnapshot finalSnapshot = await resumedPaced.send(
    () => resumed.resume(code: code, seatToken: dropSeatToken),
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
        'connection), resumed with its seat_token, and sent '
        '$resumedSendsAfterAttach message(s) on that resumed connection '
        'before the game reached a winner',
  );
}
