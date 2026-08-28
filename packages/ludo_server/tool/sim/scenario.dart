// The shared result type every scenario returns, and the failure type the
// setup and play helpers throw. Kept separate from `game.dart` so scenario
// files that only need the result type do not have to import the whole
// driver.

/// The outcome of one scenario, exactly what `simulator.dart` needs to print
/// its one required line: `PASS <name> <detail>` or `FAIL <name> <reason>`.
class ScenarioResult {
  ScenarioResult({
    required this.name,
    required this.passed,
    required this.detail,
  });

  final String name;
  final bool passed;

  /// The detail after a PASS, or the reason after a FAIL. Always one line:
  /// callers building this from an exception use its `toString()`, and
  /// every exception type this package throws produces a single-line
  /// message for exactly that reason.
  final String detail;
}

/// Thrown anywhere in a scenario's setup or play when the server did not do
/// what docs/PROTOCOL.md says it must. Caught once, at the top of each
/// scenario function, and turned into a FAIL line carrying [message]
/// unchanged -- this is not a bug in the simulator, it is a finding about
/// the server, and the message says what was expected and what happened.
class ScenarioFailure implements Exception {
  ScenarioFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
