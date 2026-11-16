/// `docs/PROTOCOL.md` section 28 rule 1: which ruleset a server plays. Pure
/// parsing, no I/O, so `bin/server.dart` and the tests share one reading of
/// the `RULESET` environment variable.
library;

/// The ruleset every room has played until section 28: the roll queue and
/// the home bonus, no yard release, a game that ends with the first winner.
const String ruleset202610 = '2026-10';

/// The ruleset of section 28: the yard release (`docs/RULES.md` rules
/// 9r-15r) and the places played out (rules 33p-39p) on top of the above.
const String ruleset202611 = '2026-11';

/// True for a value [parseRuleset] would accept as is.
bool isKnownRuleset(String value) =>
    value == ruleset202610 || value == ruleset202611;

/// Section 28 rule 1. The `RULESET` environment value: absent or empty is
/// [ruleset202610], `2026-10` and `2026-11` are themselves (surrounding
/// spaces and tabs trimmed, as `MIN_CLIENT_BUILD` is in section 27), and
/// anything else throws a [FormatException] naming the variable, for
/// `bin/server.dart` to turn into a failed start.
String parseRuleset(String? raw) {
  if (raw == null) {
    return ruleset202610;
  }
  final String trimmed = raw.replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');
  if (trimmed.isEmpty) {
    return ruleset202610;
  }
  if (!isKnownRuleset(trimmed)) {
    throw FormatException(
      'RULESET must be $ruleset202610 or $ruleset202611, got "$raw"',
    );
  }
  return trimmed;
}
