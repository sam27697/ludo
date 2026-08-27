#!/usr/bin/env bash
# One command, and the exit code is the verdict. Nothing is approved against a
# report; things are approved against this.
#
# Six gates, in the order a failure is cheapest to diagnose. Each gate is a
# function that returns 0 for pass, 1 for fail, and 77 for "not implemented
# yet". A not-implemented gate does not fail the run, but it is counted and
# printed loudly at the end, so a green run never claims more than it earned.
#
# Rule that this script exists to enforce: no work order may modify this file
# in the same order that is measured by it. Changing the harness is its own
# order, reviewed on its own.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0; TODO=0
FAILED_GATES=""; TODO_GATES=""

run_gate() {
  local name="$1"; shift
  printf '== %-24s ' "$name"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  case $rc in
    0)  echo "pass"; PASS=$((PASS+1))
        [ -n "$out" ] && echo "$out" | sed 's/^/     /' ;;
    77) echo "not implemented"; TODO=$((TODO+1)); TODO_GATES="$TODO_GATES $name"
        [ -n "$out" ] && echo "$out" | sed 's/^/     /' ;;
    *)  echo "FAIL"; FAIL=$((FAIL+1)); FAILED_GATES="$FAILED_GATES $name"
        echo "$out" | sed 's/^/     /' ;;
  esac
  return 0
}

# Resolve the Dart SDK binary the same way for every gate that needs it: PATH
# first, then $DART_SDK, then the toolchain path this environment installs it
# at. Prints the resolved path on stdout and returns 1 if none is found, so
# callers write `dart="$(resolve_dart)" || { ...; return 77; }`.
resolve_dart() {
  if command -v dart >/dev/null 2>&1; then
    command -v dart
    return 0
  elif [ -n "${DART_SDK:-}" ] && [ -x "$DART_SDK/bin/dart" ]; then
    echo "$DART_SDK/bin/dart"
    return 0
  elif [ -x /workspace/toolchains/dart-sdk/bin/dart ]; then
    echo /workspace/toolchains/dart-sdk/bin/dart
    return 0
  fi
  return 1
}

# 1. Static analysis and formatting. First because it is free and because a
# tree that does not analyse cleanly is not worth running tests against.
#
# packages/ludo_client depends on the Flutter SDK (its pubspec.yaml pins
# `sdk: flutter`), and a plain `dart` binary cannot resolve that dependency.
# Measured on this machine on 2026-08-28: with a stale
# packages/ludo_client/.dart_tool left over from an earlier `flutter pub get`
# present, both `dart analyze` and `dart format` on the client report a clean
# result; with it absent, `dart analyze` fails outright on the unresolved
# imports and `dart format` reports files as needing changes that a Flutter
# toolchain says are already correctly formatted. Either way the verdict
# tracks host history, not the tree, so this gate does not run `dart analyze`
# or `dart format` against packages/ludo_client at all. A real Flutter
# toolchain analyses and formats it instead, in the `client` CI job.
#
# What is left to check is not a fixed path list, so a directory rename
# cannot quietly narrow it: every directory directly under packages/ that has
# a pubspec.yaml is discovered here, and it is Flutter-only if that pubspec
# depends on the Flutter SDK, Dart-only otherwise. The next Flutter package
# added to this repository is excluded the same way, automatically -- nobody
# has to remember to update a glob in this file or in analysis_options.yaml.
gate_static() {
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local pkg_dir
  local -a dart_only=() flutter_only=()
  for pkg_dir in "$ROOT"/packages/*/; do
    pkg_dir="${pkg_dir%/}"
    [ -f "$pkg_dir/pubspec.yaml" ] || continue
    if grep -qE '^[[:space:]]*sdk:[[:space:]]*flutter[[:space:]]*$' "$pkg_dir/pubspec.yaml"; then
      flutter_only+=("${pkg_dir#"$ROOT"/}")
    else
      dart_only+=("${pkg_dir#"$ROOT"/}")
    fi
  done

  # A gate that checks nothing and reports green is worse than no gate. If
  # discovery above found no Dart-only package at all -- packages/ deleted or
  # renamed, or every package under it now depending on Flutter -- refuse to
  # call that a pass.
  if [ ${#dart_only[@]} -eq 0 ]; then
    echo "no Dart-only package found under packages/ -- refusing to report a pass for analysing nothing"
    return 1
  fi

  # Same failure mode one level down: a package this gate is supposed to
  # cover still exists as a directory but has been emptied of Dart source.
  local missing=""
  for pkg_dir in "${dart_only[@]}"; do
    if [ -z "$(find "$ROOT/$pkg_dir" -name '*.dart' -print -quit 2>/dev/null)" ]; then
      missing="$missing $pkg_dir"
    fi
  done
  if [ -n "$missing" ]; then
    echo "Dart-only package(s) with no .dart source under them:$missing"
    return 1
  fi

  local out rc
  out="$("$dart" analyze --fatal-infos --fatal-warnings "${dart_only[@]}" 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    echo "$out"
    return 1
  fi

  local fmt_out fmt_rc
  fmt_out="$("$dart" format --output=none --set-exit-if-changed "${dart_only[@]}" 2>&1)"; fmt_rc=$?
  if [ $fmt_rc -ne 0 ]; then
    echo "$fmt_out"
    return 1
  fi

  echo "$out"
  echo "$fmt_out"
  if [ ${#flutter_only[@]} -gt 0 ]; then
    echo "excluded here, covered by the client CI job instead:${flutter_only[*]}"
  fi
  return 0
}

# 1b. Rule 37: the engine has no clock, no network, no file access, no process
# or platform state, and no global mutable state. That is a property of the
# source text, not of behaviour, so it is a grep gate over the engine's lib/,
# not a test. Scans only packages/ludo_engine/lib/ -- the server legitimately
# uses sockets and clocks.
gate_purity() {
  local pkg_lib="$ROOT/packages/ludo_engine/lib"
  if [ ! -d "$pkg_lib" ]; then
    echo "no packages/ludo_engine/lib yet"
    return 77
  fi

  local files
  files="$(find "$pkg_lib" -name '*.dart' | sort)"
  if [ -z "$files" ]; then
    echo "no dart sources under packages/ludo_engine/lib"
    return 77
  fi

  # Clock, network, filesystem, process and platform references, plus a bare
  # dart:math (the engine's dice are SplitMix64 over an injected seed; a
  # dart:math Random anywhere in lib/ is the exact bug this gate exists to
  # catch). Word-bounded so it does not fire on a longer identifier that
  # merely contains one of these as a substring.
  local forbidden
  forbidden='\bDateTime\.now\b|\bStopwatch\b|\bTimer\b|\bFuture\.delayed\b|\bsleep\b|\bdart:io\b|\bdart:isolate\b|\bdart:ffi\b|\bdart:js\b|\bdart:html\b|\bdart:math\b|\bHttpClient\b|\bSocket\b|\bWebSocket\b|\bFile\(|\bDirectory\(|\bProcess\.|\bPlatform\.|\bRandom\(|\bRandom\.secure\b'

  # A top-level declaration (column 0) that assigns and is neither const nor
  # final nor one of the keywords that start a type, import or directive.
  # Anything left is a mutable global: two games in one server process would
  # share it.
  local mutable_top_level
  mutable_top_level='^(?!(?:const|final|class|abstract|enum|mixin|extension|typedef|import|export|part|library|void|sealed|base|interface|factory)\b)[A-Za-z_][^(=;]*=(?![=>])'

  local violations=""
  local f stripped hit
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Strip line comments before matching, so a mention of a forbidden name
    # inside a comment does not fail the gate. No block comments are in use
    # under lib/ today; if that changes this gate needs to change with it.
    stripped="$(sed -E 's#//.*##' "$f")"

    hit="$(printf '%s\n' "$stripped" | grep -nP "$forbidden" || true)"
    if [ -n "$hit" ]; then
      violations="$violations
${f#"$ROOT"/}: forbidden reference
$(printf '%s\n' "$hit" | sed 's/^/  line /')"
    fi

    hit="$(printf '%s\n' "$stripped" | grep -nP "$mutable_top_level" || true)"
    if [ -n "$hit" ]; then
      violations="$violations
${f#"$ROOT"/}: top-level mutable variable
$(printf '%s\n' "$hit" | sed 's/^/  line /')"
    fi
  done <<< "$files"

  if [ -n "$violations" ]; then
    echo "rule 37 violations:"
    echo "$violations"
    return 1
  fi

  echo "no clock, network, filesystem, process/platform or dart:math reference, and no top-level mutable state, under packages/ludo_engine/lib/"
  return 0
}

# 2. Rules unit tests. Every numbered rule in docs/RULES.md, plus section 7's
# list of the ones a naive implementation gets wrong.
gate_rules() {
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local pkg="$ROOT/packages/ludo_engine"
  local rules_dir="$pkg/test/rules"
  if [ ! -d "$rules_dir" ] || [ -z "$(find "$rules_dir" -name '*_test.dart' -print -quit 2>/dev/null)" ]; then
    echo "no rule tests yet (packages/ludo_engine/test/rules/ missing or empty)"
    return 77
  fi

  local out rc
  out="$(cd "$pkg" && "$dart" test test/rules/ 2>&1)"; rc=$?
  echo "$out"
  [ $rc -eq 0 ] && return 0
  return 1
}

# 3. The golden corpus. N complete games recorded as seed, intentions and a
# final state hash. The engine replays them and the hashes must match. A hash
# change is a defect until someone proves it was an intended rule change.
gate_golden() {
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local pkg="$ROOT/packages/ludo_engine"
  if [ ! -f "$pkg/test/golden/corpus.jsonl" ]; then
    echo "no corpus yet"
    return 77
  fi

  local out rc
  out="$(cd "$pkg" && "$dart" test test/golden_replay_test.dart 2>&1)"; rc=$?
  echo "$out"
  [ $rc -eq 0 ] && return 0
  return 1
}

# 3b. The server test suite: room and registry conformance tests under
# packages/ludo_server/test/. Not protocol conformance -- that is gate_protocol,
# still a stub -- this is the registry and room logic exercised directly.
gate_server() {
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local test_dir="$ROOT/packages/ludo_server/test"
  if [ ! -d "$test_dir" ] || [ -z "$(find "$test_dir" -name '*_test.dart' -print -quit 2>/dev/null)" ]; then
    echo "no server tests yet (packages/ludo_server/test/ missing or empty)"
    return 77
  fi

  local out rc
  out="$("$dart" test packages/ludo_server/test/ 2>&1)"; rc=$?

  # Pull the pass/fail count straight from the runner's own final summary
  # line ("+N: All tests passed." or "+N -M: Some tests failed.") instead of
  # hardcoding an expected total, so a suite that grows never needs this file
  # touched.
  local summary passed failed total
  summary="$(printf '%s\n' "$out" | grep -oE '\+[0-9]+( -[0-9]+)?: (All tests passed|Some tests failed)' | tail -n1)"
  passed="$(printf '%s' "$summary" | grep -oE '^\+[0-9]+' | tr -d '+')"
  failed="$(printf '%s' "$summary" | grep -oE ' -[0-9]+' | tr -d ' -')"
  [ -z "$passed" ] && passed=0
  [ -z "$failed" ] && failed=0
  total=$((passed + failed))

  echo "$out"
  echo "server($passed/$total)"

  [ $rc -eq 0 ] && return 0
  return 1
}

# 4. Protocol conformance. Every message type against docs/PROTOCOL.md, and the
# malformed cases: out of turn, replayed move id, a move for another seat's
# token, unknown room, full room, expired room, oversized payload, garbage.
gate_protocol() {
  echo "no server yet"
  return 77
}

# 5. The headless four-client simulator against a real server process. Create,
# share, three joins by code, a full game to a winner. Then the same with a
# client killed mid-game and reconnecting, and once with two dropping at the
# same time. This is the integration gate.
gate_simulator() {
  echo "no server yet"
  return 77
}

# 6. A real build artifact. "It compiles" is not the gate: the release bundle
# builds and the debug build installs and reaches the main screen.
gate_artifact() {
  echo "no client yet"
  return 77
}

# The specs themselves are checked from gate one, because they are the only
# thing in the tree right now and because an order dispatched against a missing
# spec is a wasted night.
gate_specs() {
  local missing=""
  for f in docs/RULES.md docs/PROTOCOL.md; do
    [ -f "$ROOT/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    echo "missing:$missing"
    return 1
  fi
  echo "docs/RULES.md docs/PROTOCOL.md present"
  return 0
}

# No secret may ever reach a commit. This gate is cheap and it runs forever.
gate_secrets() {
  local hits
  hits="$(git -C "$ROOT" ls-files 2>/dev/null \
    | grep -E '\.(jks|keystore|p12|pem|key)$|(^|/)\.env($|\.)|service-account.*\.json|google-services\.json' \
    || true)"
  if [ -n "$hits" ]; then
    echo "tracked secret-shaped files:"; echo "$hits"
    return 1
  fi
  echo "no secret-shaped file is tracked"
  return 0
}

echo "ludo-verify  $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'no git')"
echo

run_gate specs      gate_specs
run_gate secrets    gate_secrets
run_gate static     gate_static
run_gate purity     gate_purity
run_gate rules      gate_rules
run_gate golden     gate_golden
run_gate server     gate_server
run_gate protocol   gate_protocol
run_gate simulator  gate_simulator
run_gate artifact   gate_artifact

echo
echo "gates: $PASS passed, $FAIL failed, $TODO not implemented"
[ -n "$TODO_GATES" ] && echo "not implemented:$TODO_GATES"
[ -n "$FAILED_GATES" ] && echo "failed:$FAILED_GATES"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "VERDICT: fail"
  exit 1
fi

echo
echo "VERDICT: pass, with $TODO gates not yet implemented"
exit 0
