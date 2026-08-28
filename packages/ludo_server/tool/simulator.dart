// The headless four-client simulator of order 014: drives real WebSocket
// clients through a complete Ludo game against a real, separately running
// server process, over the real wire protocol of docs/PROTOCOL.md, and
// exits 0 only if every selected scenario reached the state the protocol
// says it must.
//
//   dart run tool/simulator.dart --target <url>
//       [--scenario all|full-game|reconnect|double-drop]
//       [--timeout-seconds N] [--players N]
//
// See docs/SIMULATOR.md for what each scenario proves and what each
// failure line means.

import 'dart:async';
import 'dart:io';

import 'sim/args.dart';
import 'sim/scenario.dart';
import 'sim/scenario_double_drop.dart';
import 'sim/scenario_full_game.dart';
import 'sim/scenario_reconnect.dart';

typedef _ScenarioRunner = Future<ScenarioResult> Function(
    Uri target, int players);

const Map<String, _ScenarioRunner> _runners = <String, _ScenarioRunner>{
  'full-game': runFullGame,
  'reconnect': runReconnect,
  'double-drop': runDoubleDrop,
};

Future<void> main(List<String> arguments) async {
  final SimulatorArgs args;
  try {
    args = parseArgs(arguments);
  } on ArgsError catch (error) {
    stderr.writeln('simulator: $error');
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

    final _ScenarioRunner runner = _runners[scenarioName]!;
    ScenarioResult result;
    try {
      result = await runner(args.target, args.players).timeout(remaining);
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
