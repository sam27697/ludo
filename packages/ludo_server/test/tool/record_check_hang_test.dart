// Reproduces the defect work/ludo/orders/217-simulator-checks-verify-record.md
// records against tool/sim/record_check.dart, in that order's own
// "## Verdict" section (run 63, "RETURN 1"):
//
//   Defect 1. packages/ludo_server/tool/sim/record_check.dart, _get and
//   the two body reads: no timeout anywhere. Against a verify host that
//   accepts the TCP connection and never answers, the scenario prints its
//   overall-budget FAIL, but the hung socket keeps the process alive and
//   it never exits.
//
// and what "fixed" means, from the same section:
//
//   HttpClient.connectionTimeout set, and each of getUrl, request.close()
//   and the body read bounded by a timeout (15 seconds each is fine); a
//   timeout becomes a ScenarioFailure whose text names the URL and says
//   no response came within the limit, and the finally then force-closes
//   the client.
//
// This file drives the same three real processes the order's own
// acceptance arm 6 drives: a TCP listener that accepts a connection and
// never answers, a real packages/ludo_server/bin/server.dart pointed at
// it through LUDO_VERIFY_BASE_URL, and a real
// packages/ludo_server/tool/simulator.dart --fetch-record run against
// that server -- not a mock of any of the three. The listener here is
// in-process (a bound ServerSocket that accepts and never writes) rather
// than the external work/ludo/evidence/217-blackhole.py, so this file
// needs no external interpreter and no fixed port; the behaviour it
// presents on the wire -- accept, then silence -- is identical.
//
// A test cannot wait forever for a process that, on the unfixed source,
// genuinely never exits on its own: the order's own arm 6 needed
// `timeout 420` wrapped around the identical invocation and used every
// one of those 420 seconds (exit 124). _hangBudget below is this file's
// equivalent of that outer `timeout`, set well above how long a real
// --players 2 game against a live local server takes end to end
// (measured here at approximately 11s, dart run's own startup included --
// see the reproduction note in the failure message below) and well below
// 420s, so this test fails fast and says why instead of stalling the
// suite for anywhere near that long.
//
// This file does not modify tool/sim/record_check.dart or any other
// production source. It only proves, against the real process, whether
// the change "Fixed means" describes has been made.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// How long this test waits for the simulator process to exit on its own
/// before concluding it has hung and killing it by PID. See the file
/// comment for how this was chosen.
const Duration _hangBudget = Duration(seconds: 75);

/// How long this test waits for the server subprocess to print its
/// "listening on port" line before concluding setup itself, not the
/// thing under test, is broken.
const Duration _setupBudget = Duration(seconds: 30);

/// The absolute path to this package's own root directory, resolved from
/// the package configuration rather than from the current working
/// directory or from `Platform.script`. Copied from
/// `app_links_route_test.dart`'s helper of the same name and purpose (which
/// in turn copied it from `privacy_route_test.dart`); that file's own copy
/// is private to it and this file cannot import a test file to reuse it, so
/// it is duplicated here rather than left out. Needed because `dart test
/// packages/ludo_server/test/` (the harness and CI shape) runs with
/// `Directory.current` at the repository root, where `bin/server.dart` and
/// `tool/simulator.dart` do not exist; the two subprocesses below must
/// start in this package's directory regardless of where the test runner
/// itself was launched from.
Future<String>? _packageRootFuture;

Future<String> _packageRoot() {
  return _packageRootFuture ??= () async {
    final Uri? libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:ludo_server/ludo_server.dart'),
    );
    if (libUri == null) {
      fail(
        'could not resolve package:ludo_server/ludo_server.dart to a file '
        'URI; cannot locate bin/server.dart for the subprocess tests below',
      );
    }
    final Directory packageRoot = File.fromUri(libUri).parent.parent;
    return packageRoot.path;
  }();
}

void main() {
  test(
    'full-game --fetch-record exits (does not hang) against a verify '
    'host that accepts the connection and never answers',
    () async {
      final _BlackHole blackHole = await _BlackHole.bind();
      Process? server;
      Process? sim;
      _LineCollector? serverOut;
      _LineCollector? serverErr;
      _LineCollector? simOut;
      _LineCollector? simErr;
      try {
        final String packageRoot = await _packageRoot();
        server = await Process.start(
          'dart',
          <String>['run', 'bin/server.dart'],
          workingDirectory: packageRoot,
          environment: <String, String>{
            'PORT': '0',
            'LUDO_VERIFY_BASE_URL': 'http://127.0.0.1:${blackHole.port}/v/',
          },
        );
        serverOut = _LineCollector(server.stdout);
        serverErr = _LineCollector(server.stderr);
        final int serverPort =
            await _readServerPort(server, serverOut, serverErr);

        sim = await Process.start(
          'dart',
          <String>[
            'run',
            'tool/simulator.dart',
            '--target',
            'ws://127.0.0.1:$serverPort',
            '--scenario',
            'full-game',
            '--players',
            '2',
            '--fetch-record',
          ],
          workingDirectory: packageRoot,
        );
        simOut = _LineCollector(sim.stdout);
        simErr = _LineCollector(sim.stderr);

        final Stopwatch stopwatch = Stopwatch()..start();
        int? exitCode;
        try {
          exitCode = await sim.exitCode.timeout(_hangBudget);
        } on TimeoutException {
          exitCode = null;
        }
        stopwatch.stop();

        if (exitCode == null) {
          sim.kill(ProcessSignal.sigkill);
          await sim.exitCode;
          fail(
            'tool/simulator.dart --scenario full-game --fetch-record did '
            'not exit within ${_hangBudget.inSeconds}s against a verify '
            'host that accepts the TCP connection on '
            '127.0.0.1:${blackHole.port} and never answers; still '
            'running as pid ${sim.pid} when this test killed it.\n'
            '\n'
            'Expected, per work/ludo/orders/'
            '217-simulator-checks-verify-record.md, "## Verdict", '
            '"Fixed means": packages/ludo_server/tool/sim/'
            'record_check.dart sets HttpClient.connectionTimeout and '
            'bounds getUrl, request.close() and the body read by a '
            'timeout each; the timeout becomes a ScenarioFailure naming '
            'the <verify_url>.json URL and saying no response came '
            'within the limit; the finally then force-closes the '
            'client; the process exits non-zero on its own.\n'
            '\n'
            'Actual: packages/ludo_server/tool/sim/record_check.dart '
            'sets no timeout anywhere -- read directly: `_get` (around '
            'line 232) awaits `client.getUrl(uri)` and '
            '`request.close()` with no timeout on either; '
            '`_checkJsonRecord` (around line 74) and `_checkHtmlPage` '
            '(around line 216) each await a body read '
            '(`response.transform(utf8.decoder).join()` and '
            '`response.drain<void>()`) with no timeout either. Against '
            'a peer that accepts the connection and never answers, one '
            'of those awaits never completes, which keeps this '
            'isolate\'s event loop non-empty, which keeps the process '
            'alive past main() finishing -- this reproduces run 63\'s '
            'Verdict, Defect 1, exactly.\n'
            '\n'
            'Reproduce directly (elapsed seconds on the order\'s own '
            'acceptance arm 6 shape): export '
            'PATH="/workspace/toolchains/flutter/bin:'
            '/workspace/toolchains/dart-sdk/bin:\$PATH"; cd '
            'packages/ludo_server; start a listener that accepts on '
            '127.0.0.1 and never writes (a bare ServerSocket, or '
            'work/ludo/evidence/217-blackhole.py); point '
            'LUDO_VERIFY_BASE_URL at it; PORT=0 dart run bin/server.dart '
            '&; note the port from its "listening on port" line; then '
            'timeout 420 dart run tool/simulator.dart --target '
            'ws://127.0.0.1:<port> --scenario full-game --players 2 '
            '--fetch-record: prints a FAIL line and then hangs until '
            '`timeout` kills it, exit 124.\n'
            '\n'
            'server stdout so far: ${serverOut.linesSoFar}\n'
            'server stderr so far: ${serverErr.linesSoFar}\n'
            'simulator stdout so far: ${simOut.linesSoFar}\n'
            'simulator stderr so far: ${simErr.linesSoFar}',
          );
        }

        // Only reached once record_check.dart actually bounds its
        // fetches and the process exits on its own -- the "fixed" shape
        // the order asks for. Left in, unmodified, so this test starts
        // passing the moment that source change lands, and keeps
        // checking the exact shape "Fixed means" pins: exit 1, a FAIL
        // line, that line naming the .json URL, and that line saying the
        // wait had a limit that was reached.
        final List<String> stdoutLines = simOut.linesSoFar;
        final String stdout = stdoutLines.join('\n');
        expect(
          exitCode,
          equals(1),
          reason: 'expected the fetch timeout to fail scenario full-game '
              'and exit the process 1; got exit code $exitCode after '
              '${stopwatch.elapsed.inSeconds}s. stdout:\n$stdout',
        );
        final RegExp failLine = RegExp(r'^FAIL full-game .*$');
        expect(
          stdoutLines.any(failLine.hasMatch),
          isTrue,
          reason: 'expected a line matching "FAIL full-game ..."; '
              'stdout:\n$stdout',
        );
        final RegExp jsonUrlNamed =
            RegExp(r'https?://127\.0\.0\.1:\d+/v/\S+\.json');
        expect(
          jsonUrlNamed.hasMatch(stdout),
          isTrue,
          reason: 'expected the FAIL line to name the <verify_url>.json '
              'URL the fetch could not reach, per "Fixed means"; '
              'stdout:\n$stdout',
        );
        final RegExp saysNoResponseWithinLimit = RegExp(
          r'\btime[- ]?(?:d\s+out|out)\b|\bwithin\b[^.\n]*\b(?:second|s)\b',
          caseSensitive: false,
        );
        expect(
          saysNoResponseWithinLimit.hasMatch(stdout),
          isTrue,
          reason: 'expected the FAIL line to say no response came within '
              'the limit, per "Fixed means"; stdout:\n$stdout',
        );
      } finally {
        final Process? simProc = sim;
        if (simProc != null) {
          simProc.kill(ProcessSignal.sigkill);
          await simProc.exitCode;
        }
        final Process? serverProc = server;
        if (serverProc != null) {
          serverProc.kill(ProcessSignal.sigterm);
          await serverProc.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              serverProc.kill(ProcessSignal.sigkill);
              return serverProc.exitCode;
            },
          );
        }
        await blackHole.close();
      }
    },
    timeout: Timeout(_hangBudget + const Duration(seconds: 60)),
  );
}

Future<int> _readServerPort(
  Process server,
  _LineCollector serverOut,
  _LineCollector serverErr,
) async {
  final RegExp portLine = RegExp(r'^ludo_server listening on port (\d+)$');
  String line;
  try {
    line = await serverOut.stream.firstWhere(portLine.hasMatch).timeout(
          _setupBudget,
        );
  } on TimeoutException {
    fail(
      'bin/server.dart did not print its "listening on port" line within '
      '${_setupBudget.inSeconds}s; lines so far: ${serverOut.linesSoFar}',
    );
  } on StateError {
    // Stream.firstWhere throws "Bad state: No element" (with no further
    // detail) when the source stream closes -- here, the server process
    // exiting -- without ever producing a matching line. That message
    // alone does not say why the server is gone, which is what the next
    // person staring at this test red actually needs. Report the
    // server's own exit code and everything it wrote to stderr instead.
    final int exitCode = await server.exitCode;
    fail(
      'bin/server.dart exited with code $exitCode before printing its '
      '"listening on port" line; stdout so far: ${serverOut.linesSoFar}; '
      'stderr so far: ${serverErr.linesSoFar}',
    );
  }
  return int.parse(portLine.firstMatch(line)!.group(1)!);
}

/// Collects every line a process output stream produces, both as a
/// replayable broadcast stream (for `firstWhere`, used once to find the
/// server's readiness line) and as a running buffer (so a failure message
/// can quote everything seen so far, including lines produced after the
/// process is killed mid-test).
class _LineCollector {
  _LineCollector(Stream<List<int>> source) {
    source.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (String line) {
        _lines.add(line);
        _controller.add(line);
      },
      onDone: _controller.close,
    );
  }

  final List<String> _lines = <String>[];
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;
  List<String> get linesSoFar => List<String>.unmodifiable(_lines);
}

/// A TCP listener that accepts every connection and then says nothing,
/// forever -- the same shape on the wire as
/// work/ludo/evidence/217-blackhole.py, in-process so this test needs no
/// external interpreter and binds an ephemeral port rather than a fixed
/// one.
class _BlackHole {
  _BlackHole._(this._server);

  final ServerSocket _server;
  final List<Socket> _held = <Socket>[];

  static Future<_BlackHole> bind() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final _BlackHole hole = _BlackHole._(server);
    server.listen((Socket socket) {
      hole._held.add(socket);
      // Never write, never close: the entire point is a peer that
      // accepts the TCP connection and then, forever, says nothing.
      socket.listen((List<int> _) {});
    });
    return hole;
  }

  int get port => _server.port;

  Future<void> close() async {
    for (final Socket socket in _held) {
      socket.destroy();
    }
    await _server.close();
  }
}
