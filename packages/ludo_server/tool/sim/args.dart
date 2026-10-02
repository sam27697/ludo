// Argument parsing for the frozen invocation of order 014, plus the
// order 217 addition of --fetch-record, and the order 235 (run 67) addition
// of `rematch` to the set of names `--scenario` accepts:
//
//   dart run tool/simulator.dart --target <url>
//       [--scenario all|full-game|reconnect|double-drop|rematch]
//       [--timeout-seconds N] [--players N] [--fetch-record]
//
// No third-party argument-parsing package: the whole surface is a handful
// of flags, most taking exactly one value, and a hand-rolled loop is easier
// to audit against that frozen list than a dependency would be.

/// The `--scenario` values this simulator understands. `rematch` is in this
/// list (run 67) so `--scenario rematch` is validated here like any other
/// name instead of being stripped out of the argument list before it
/// reaches this file, but it is deliberately excluded from [scenariosInAll]
/// below: the gate runs `all` under a 210s bound sized for the three
/// scenarios order 014 shipped, and widening that bound to also fit a
/// second full game is a later harness order's job, not this one's.
const List<String> knownScenarios = <String>[
  'full-game',
  'reconnect',
  'double-drop',
  'rematch',
];

/// The `--scenario` values `all` expands to, in the order they run. Every
/// entry here is also in [knownScenarios]; the reverse is not required, and
/// `rematch` is the one name in [knownScenarios] that is not here.
const List<String> scenariosInAll = <String>[
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
    required this.fetchRecord,
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

  /// Order 217: after each scenario's game ends, fetch and verify the
  /// stored record at `<verify_url>.json` and `<verify_url>` against what
  /// the simulator saw on the wire. Off by default -- see [usage] and
  /// docs/SIMULATOR.md for why.
  final bool fetchRecord;

  /// The scenario names this run should execute, in a fixed order,
  /// regardless of whether `--scenario` named one of them or `all`.
  /// `all` expands to [scenariosInAll], not [knownScenarios]: `rematch` is a
  /// valid `--scenario` value but never runs as part of `all`.
  List<String> get selectedScenarios =>
      scenario == 'all' ? scenariosInAll : <String>[scenario];
}

SimulatorArgs parseArgs(List<String> arguments) {
  String? target;
  String scenario = 'all';
  int timeoutSeconds = 180;
  int players = 4;
  bool fetchRecord = false;

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
      case '--fetch-record':
        fetchRecord = true;
        i += 1;
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
    fetchRecord: fetchRecord,
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
usage: dart run tool/simulator.dart --target <url> [--scenario all|full-game|reconnect|double-drop|rematch] [--timeout-seconds N] [--players N] [--fetch-record]

  --target           required. Base WebSocket URL of a running server, ws:// or wss://.
  --scenario         default: all. rematch is valid but never runs as part of all; select it on its own.
  --timeout-seconds  default: 180. Bounds the whole run, not one frame.
  --players          default: 4. Seats to play with, 2 to 4.
  --fetch-record     default: off. After each game ends, fetch <verify_url>.json
                      and <verify_url> and check them against the wire. Off by
                      default because a local server hands out verify_url values
                      on the default production base -- turning it on against a
                      local server would check the wrong machine unless
                      LUDO_VERIFY_BASE_URL points the server at that same
                      local server.
''';
