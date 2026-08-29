// Argument parsing for the frozen invocation of order 014:
//
//   dart run tool/simulator.dart --target <url>
//       [--scenario all|full-game|reconnect|double-drop]
//       [--timeout-seconds N] [--players N]
//
// No third-party argument-parsing package: the whole surface is four flags,
// each taking exactly one value, and a hand-rolled loop is easier to audit
// against that frozen list than a dependency would be.

/// The `--scenario` values this simulator understands, in the order they
/// run under `all`.
const List<String> knownScenarios = <String>[
  'full-game',
  'reconnect',
  'double-drop',
];

/// Thrown for any malformed invocation. The simulator prints [message] to
/// stderr and exits non-zero without attempting to connect anywhere.
class ArgsError implements Exception {
  ArgsError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The parsed, validated command line.
class SimulatorArgs {
  SimulatorArgs({
    required this.target,
    required this.scenario,
    required this.timeoutSeconds,
    required this.players,
  });

  /// The base WebSocket URL of the server under test, `ws://` or `wss://`,
  /// exactly as given on the command line -- nothing is appended to it.
  final Uri target;

  /// `all`, or one of [knownScenarios].
  final String scenario;

  /// Bounds the whole run, not one frame. Defaults to 180.
  final int timeoutSeconds;

  /// Seats to play with, 2 to 4. Defaults to 4.
  final int players;

  /// The scenario names this run should execute, in a fixed order,
  /// regardless of whether `--scenario` named one of them or `all`.
  List<String> get selectedScenarios =>
      scenario == 'all' ? knownScenarios : <String>[scenario];
}

SimulatorArgs parseArgs(List<String> arguments) {
  String? target;
  String scenario = 'all';
  int timeoutSeconds = 180;
  int players = 4;

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
      case '--timeout-seconds':
        final String raw = _valueAfter(arguments, i, arg);
        final int? parsed = int.tryParse(raw);
        if (parsed == null) {
          throw ArgsError('--timeout-seconds must be an integer, got "$raw"');
        }
        timeoutSeconds = parsed;
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
      default:
        throw ArgsError('unrecognised argument: $arg');
    }
  }

  if (target == null) {
    throw ArgsError('--target is required');
  }
  Uri parsedTarget;
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

  if (timeoutSeconds <= 0) {
    throw ArgsError(
      '--timeout-seconds must be positive, got $timeoutSeconds',
    );
  }

  if (players < 2 || players > 4) {
    throw ArgsError('--players must be 2, 3 or 4, got $players');
  }

  return SimulatorArgs(
    target: parsedTarget,
    scenario: scenario,
    timeoutSeconds: timeoutSeconds,
    players: players,
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
usage: dart run tool/simulator.dart --target <url> [--scenario all|full-game|reconnect|double-drop] [--timeout-seconds N] [--players N]

  --target           required. Base WebSocket URL of a running server, ws:// or wss://.
  --scenario         default: all
  --timeout-seconds  default: 180. Bounds the whole run, not one frame.
  --players          default: 4. Seats to play with, 2 to 4.
''';
