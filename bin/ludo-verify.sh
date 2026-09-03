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

# Same resolution order as resolve_dart, for the Flutter SDK: PATH first,
# then $FLUTTER_SDK, then the toolchain path this environment installs it at.
resolve_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  elif [ -n "${FLUTTER_SDK:-}" ] && [ -x "$FLUTTER_SDK/bin/flutter" ]; then
    echo "$FLUTTER_SDK/bin/flutter"
    return 0
  elif [ -x /workspace/toolchains/flutter/bin/flutter ]; then
    echo /workspace/toolchains/flutter/bin/flutter
    return 0
  fi
  return 1
}

# The directories directly under packages/ that have a pubspec.yaml, split by
# whether that pubspec pins `sdk: flutter`. Shared by gate_static and
# gate_client_static so the two agree on the same partition without either
# one hardcoding a package name -- the next Flutter package added to this
# repository lands in FLUTTER_ONLY_PKGS automatically. Resets and repopulates
# the two globals on every call rather than appending, so calling it twice in
# one run never doubles the list.
discover_packages() {
  DART_ONLY_PKGS=(); FLUTTER_ONLY_PKGS=()
  local pkg_dir
  for pkg_dir in "$ROOT"/packages/*/; do
    pkg_dir="${pkg_dir%/}"
    [ -f "$pkg_dir/pubspec.yaml" ] || continue
    if grep -qE '^[[:space:]]*sdk:[[:space:]]*flutter[[:space:]]*$' "$pkg_dir/pubspec.yaml"; then
      FLUTTER_ONLY_PKGS+=("${pkg_dir#"$ROOT"/}")
    else
      DART_ONLY_PKGS+=("${pkg_dir#"$ROOT"/}")
    fi
  done
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

  discover_packages
  local -a dart_only=("${DART_ONLY_PKGS[@]}") flutter_only=("${FLUTTER_ONLY_PKGS[@]}")

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

  # A tree that has never had `dart pub get` run has no
  # .dart_tool/package_config.json, so every third-party import in these
  # packages is unresolved and `dart analyze` reports a wall of
  # uri_does_not_exist / undefined_function errors that say nothing about the
  # code. dart_only is a pub workspace (root pubspec.yaml has `workspace:`
  # listing them), so one `dart pub get` at the repo root resolves all of
  # them at once. Run it unconditionally rather than only when the config
  # file is missing: on an already-resolved tree it is a fast no-op, and a
  # conditional here would just move the false-red to whatever check decided
  # "resolved enough."
  local pubget_out pubget_rc
  pubget_out="$(cd "$ROOT" && "$dart" pub get 2>&1)"; pubget_rc=$?
  if [ $pubget_rc -ne 0 ]; then
    echo "dart pub get failed, so dependencies are unresolved and analysis would report nothing but unresolved imports:"
    echo "$pubget_out"
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
    echo "excluded here, covered by the client_static gate instead:${flutter_only[*]}"
  fi
  return 0
}

# 1a. Static analysis and formatting for the packages gate_static excludes.
# Uses the same discovery, so it never needs telling about a Flutter package
# by name. Requires a real Flutter SDK -- a plain `dart` binary cannot
# resolve a pubspec that pins `sdk: flutter` -- and reports "not implemented"
# rather than a pass when none is reachable, the same way gate_protocol and
# gate_artifact already do for their own missing tools.
#
# Runs `flutter pub get` before analysing, for the same reason gate_static
# now runs `dart pub get` first: on a package that has never been resolved,
# `flutter analyze` triggers its own implicit pub get but still reports the
# generated localization sources as missing, because the analyzer's snapshot
# of the filesystem is taken before generation finishes. Resolving first,
# explicitly, is what makes the first analyze on a virgin tree agree with
# every analyze after it.
#
# Does not run `flutter test`. That is the client CI job's, and a several-
# minute test run inside a gate people run constantly is how a harness stops
# being run.
gate_client_static() {
  local flutter
  flutter="$(resolve_flutter)" || {
    echo "no Flutter SDK found on PATH, in \$FLUTTER_SDK, or at /workspace/toolchains/flutter/bin/flutter"
    return 77
  }
  local dart="$(dirname "$flutter")/dart"

  discover_packages
  local -a flutter_only=("${FLUTTER_ONLY_PKGS[@]}")

  # Same two refusals gate_static makes: an empty check that reports green is
  # worse than no gate at all.
  if [ ${#flutter_only[@]} -eq 0 ]; then
    echo "no Flutter package found under packages/ -- refusing to report a pass for analysing nothing"
    return 1
  fi

  local pkg_dir missing=""
  for pkg_dir in "${flutter_only[@]}"; do
    if [ -z "$(find "$ROOT/$pkg_dir" -name '*.dart' -print -quit 2>/dev/null)" ]; then
      missing="$missing $pkg_dir"
    fi
  done
  if [ -n "$missing" ]; then
    echo "Flutter package(s) with no .dart source under them:$missing"
    return 1
  fi

  local report="" pkg_out rc
  for pkg_dir in "${flutter_only[@]}"; do
    pkg_out="$(cd "$ROOT/$pkg_dir" && "$flutter" pub get 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then
      echo "flutter pub get failed in $pkg_dir, so dependencies are unresolved and analysis would be meaningless:"
      echo "$pkg_out"
      return 1
    fi

    pkg_out="$(cd "$ROOT/$pkg_dir" && "$flutter" analyze 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then
      echo "flutter analyze failed in $pkg_dir:"
      echo "$pkg_out"
      return 1
    fi
    report="$report
$pkg_dir: $pkg_out"

    pkg_out="$(cd "$ROOT/$pkg_dir" && "$dart" format --output=none --set-exit-if-changed . 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then
      echo "dart format --output=none --set-exit-if-changed . failed in $pkg_dir:"
      echo "$pkg_out"
      return 1
    fi
    report="$report
$pkg_dir: $pkg_out"
  done

  printf '%s\n' "$report" | sed '/^$/d'
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

# 3a. The fair_dice test suite: the hash-chain build, reveal verification and
# HMAC draw against packages/fair_dice/test/vectors.json, the frozen oracle
# for the scheme. Run from inside the package because the suite opens
# test/vectors.json relative to its own working directory, the same way the
# `dart test` invocation for gate_rules and gate_golden does.
gate_dice() {
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local pkg="$ROOT/packages/fair_dice"
  local test_dir="$pkg/test"
  if [ ! -d "$test_dir" ] || [ -z "$(find "$test_dir" -name '*_test.dart' -print -quit 2>/dev/null)" ]; then
    echo "no dice tests yet (packages/fair_dice/test/ missing or empty)"
    return 77
  fi

  local out rc
  out="$(cd "$pkg" && "$dart" test test/ 2>&1)"; rc=$?

  # Pull the pass/fail count straight from the runner's own final summary
  # line ("+N: All tests passed.", "+N -M: Some tests failed.", or, once a
  # suite has a skip: in it, "+N ~S: All tests passed." / "+N ~S -M: Some
  # tests failed.") instead of hardcoding an expected total, so a suite that
  # grows never needs this file touched. The middle "~S" group used to be
  # absent from this pattern entirely, which meant a suite with any skipped
  # test matched nothing at all and silently reported 0/0 here.
  local summary passed skipped failed total
  summary="$(printf '%s\n' "$out" | grep -oE '\+[0-9]+( ~[0-9]+)?( -[0-9]+)?: (All tests passed|Some tests failed)' | tail -n1)"
  passed="$(printf '%s' "$summary" | grep -oE '^\+[0-9]+' | tr -d '+')"
  skipped="$(printf '%s' "$summary" | grep -oE ' ~[0-9]+' | tr -d ' ~')"
  failed="$(printf '%s' "$summary" | grep -oE ' -[0-9]+' | tr -d ' -')"
  [ -z "$passed" ] && passed=0
  [ -z "$skipped" ] && skipped=0
  [ -z "$failed" ] && failed=0
  total=$((passed + failed))

  echo "$out"
  if [ "$skipped" -gt 0 ]; then
    echo "dice($passed/$total, $skipped skipped)"
  else
    echo "dice($passed/$total)"
  fi

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
  # line ("+N: All tests passed.", "+N -M: Some tests failed.", or, once a
  # suite has a skip: in it, "+N ~S: All tests passed." / "+N ~S -M: Some
  # tests failed.") instead of hardcoding an expected total, so a suite that
  # grows never needs this file touched. The middle "~S" group used to be
  # absent from this pattern entirely, which meant a suite with any skipped
  # test matched nothing at all and silently reported 0/0 here -- true of
  # this very gate as of run 18, which had a real "~5" in its runner line
  # and printed server(0/0) regardless.
  local summary passed skipped failed total
  summary="$(printf '%s\n' "$out" | grep -oE '\+[0-9]+( ~[0-9]+)?( -[0-9]+)?: (All tests passed|Some tests failed)' | tail -n1)"
  passed="$(printf '%s' "$summary" | grep -oE '^\+[0-9]+' | tr -d '+')"
  skipped="$(printf '%s' "$summary" | grep -oE ' ~[0-9]+' | tr -d ' ~')"
  failed="$(printf '%s' "$summary" | grep -oE ' -[0-9]+' | tr -d ' -')"
  [ -z "$passed" ] && passed=0
  [ -z "$skipped" ] && skipped=0
  [ -z "$failed" ] && failed=0
  total=$((passed + failed))

  echo "$out"
  if [ "$skipped" -gt 0 ]; then
    echo "server($passed/$total, $skipped skipped)"
  else
    echo "server($passed/$total)"
  fi

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
  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local server_pkg="$ROOT/packages/ludo_server"
  local sim_tool="$server_pkg/tool/simulator.dart"
  if [ ! -f "$sim_tool" ]; then
    echo "no packages/ludo_server/tool/simulator.dart yet"
    return 77
  fi

  # Pick a free port instead of hardcoding one: scan a small range with
  # bash's own /dev/tcp and take the first one nothing answers a connect
  # attempt on. A gate that goes red because something else on the box holds
  # a fixed port is a gate nobody will trust.
  local port="" candidate
  for candidate in $(seq 8123 8223); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
      continue
    fi
    port="$candidate"
    break
  done
  if [ -z "$port" ]; then
    echo "no free TCP port found in 8123-8223 to run the simulator's server on"
    return 1
  fi

  # Deliberately not `local`: the EXIT trap below still needs to read these
  # after gate_simulator's own stack frame is gone, since the trap fires at
  # the exit of the surrounding subshell, not at the return of this
  # function. Nothing outside this one subshell ever sees them -- run_gate
  # captures gate_simulator's output through a command substitution, and a
  # command substitution runs in its own subshell, so these die with it.
  server_log="$(mktemp "${TMPDIR:-/tmp}/ludo-verify-sim-server.XXXXXX")"
  server_pid=""

  # Fires on a normal return, on the simulator failing, on the wall-clock
  # bound below, and on the script being interrupted -- exactly the set of
  # exits that must not leave a server holding the port.
  cleanup() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
      kill "$server_pid" 2>/dev/null
      local waited=0
      while kill -0 "$server_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
      kill -0 "$server_pid" 2>/dev/null && kill -9 "$server_pid" 2>/dev/null
      wait "$server_pid" 2>/dev/null
    fi
    rm -f "$server_log"
  }
  trap cleanup EXIT INT TERM

  # exec replaces this backgrounded subshell with the server process itself,
  # so $! below is the server's own pid rather than a wrapper shell's, and
  # one kill is enough to stop it.
  (cd "$server_pkg" && exec env PORT="$port" "$dart" run bin/server.dart) \
    >"$server_log" 2>&1 &
  server_pid=$!

  # Poll /health until it actually answers, rather than sleeping a fixed
  # amount and hoping the server is up by then.
  local health_ok=0 waited_ms=0
  while [ "$waited_ms" -lt 30000 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server process exited before it ever answered /health; its output:"
      sed 's/^/     /' "$server_log"
      return 1
    fi
    if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$port/health" 2>/dev/null; then
      health_ok=1
      break
    fi
    sleep 0.2
    waited_ms=$((waited_ms + 200))
  done

  if [ "$health_ok" -ne 1 ]; then
    echo "server on 127.0.0.1:$port never answered /health within 30s; its output:"
    sed 's/^/     /' "$server_log"
    return 1
  fi

  # The simulator bounds its own run at --timeout-seconds (180 by default);
  # this outer `timeout` is a second, independent bound so a hang that the
  # simulator's own internal timeout somehow fails to catch still cannot
  # hang the harness forever. -k gives it 10s past the TERM before a KILL.
  local sim_out sim_rc
  sim_out="$(cd "$server_pkg" && timeout -k 10 210 "$dart" run tool/simulator.dart \
    --target "ws://127.0.0.1:$port" --scenario all 2>&1)"
  sim_rc=$?

  echo "$sim_out"

  local sim_summary sim_passed sim_failed sim_total
  sim_summary="$(printf '%s\n' "$sim_out" | grep -oE 'simulator: [0-9]+ passed, [0-9]+ failed' | tail -n1)"
  sim_passed="$(printf '%s' "$sim_summary" | grep -oE '[0-9]+ passed' | grep -oE '^[0-9]+')"
  sim_failed="$(printf '%s' "$sim_summary" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+')"
  [ -z "$sim_passed" ] && sim_passed=0
  [ -z "$sim_failed" ] && sim_failed=0
  sim_total=$((sim_passed + sim_failed))
  echo "simulator($sim_passed/$sim_total)"

  if [ "$sim_rc" -eq 124 ]; then
    echo "simulator did not finish within this gate's own 210s wall-clock bound"
    return 1
  fi

  [ "$sim_rc" -eq 0 ] && return 0
  return 1
}

# 5a. The client's own wire smoke: packages/ludo_client/tool/wire_smoke.dart
# drives RoomConnection, WsTransport, Frame and RoomSnapshot -- the net stack
# that actually ships in the APK -- through a real WebSocket against a real
# server process. gate_simulator above proves the server with its own,
# separate frame-building client; this proves the client package instead.
#
# packages/ludo_client pins `sdk: flutter`, so its dependencies resolve with
# `flutter pub get`, not `dart pub get` -- resolve_flutter is required here
# the same way gate_client_static requires it, and this gate reports 77, not
# a failure, when no Flutter SDK is reachable, naming what was missing. Once
# resolved, wire_smoke.dart itself only imports dart:async, dart:io,
# dart:isolate and four files under lib/src/net/ that pull in nothing from
# Flutter, so it runs under a plain `dart run` -- the `dart` binary beside
# the resolved `flutter`, the same derivation gate_client_static uses.
#
# The server this drives comes from packages/ludo_server and is started the
# same way gate_simulator starts it: a free port picked by scanning, `exec`
# in a backgrounded subshell so $! is the server's own pid, a poll of
# /health instead of a fixed sleep, and an EXIT/INT/TERM trap that stops it
# on every exit path. Variable names below are prefixed cw_ so they cannot be
# confused with gate_simulator's own server_log/server_pid/cleanup, even
# though reusing those names would in fact be safe -- each gate runs in its
# own subshell, forked fresh by run_gate's command substitution, and gate_
# simulator's subshell has already exited by the time this one starts.
gate_client_wire() {
  local flutter
  flutter="$(resolve_flutter)" || {
    echo "no Flutter SDK found on PATH, in \$FLUTTER_SDK, or at /workspace/toolchains/flutter/bin/flutter"
    return 77
  }
  local client_dart="$(dirname "$flutter")/dart"

  local dart
  dart="$(resolve_dart)" || {
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  }

  local client_pkg="$ROOT/packages/ludo_client"
  local wire_tool="$client_pkg/tool/wire_smoke.dart"
  if [ ! -f "$wire_tool" ]; then
    echo "no packages/ludo_client/tool/wire_smoke.dart yet"
    return 77
  fi

  local server_pkg="$ROOT/packages/ludo_server"
  if [ ! -f "$server_pkg/bin/server.dart" ]; then
    echo "no packages/ludo_server/bin/server.dart yet, so there is nothing to run wire_smoke.dart against"
    return 77
  fi

  # A tree that has never had `flutter pub get` run in packages/ludo_client
  # has no .dart_tool/package_config.json there, so `dart run tool/
  # wire_smoke.dart` cannot even resolve its own `package:ludo_client/...`
  # imports. Run it unconditionally, the same way gate_static and
  # gate_client_static run their own pub get unconditionally: a fast no-op
  # on an already-resolved tree, never a false red from stale state.
  local pubget_out pubget_rc
  pubget_out="$(cd "$client_pkg" && "$flutter" pub get 2>&1)"; pubget_rc=$?
  if [ $pubget_rc -ne 0 ]; then
    echo "flutter pub get failed in packages/ludo_client, so wire_smoke.dart cannot resolve its own imports:"
    echo "$pubget_out"
    return 1
  fi

  # Pick a free port instead of hardcoding one, exactly as gate_simulator
  # does, and independently of whatever port that gate itself picked or
  # released -- the two gates never run at the same time, but there is no
  # reason to assume the same port stays free between them.
  local port="" candidate
  for candidate in $(seq 8123 8223); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
      continue
    fi
    port="$candidate"
    break
  done
  if [ -z "$port" ]; then
    echo "no free TCP port found in 8123-8223 to run the server on"
    return 1
  fi

  # Deliberately not `local`, for the same reason gate_simulator's server_log
  # and server_pid are not: the EXIT trap below reads these after this
  # function's own stack frame is gone. Nothing outside this one subshell
  # ever sees them.
  cw_server_log="$(mktemp "${TMPDIR:-/tmp}/ludo-verify-wire-server.XXXXXX")"
  cw_server_pid=""

  cw_cleanup() {
    if [ -n "$cw_server_pid" ] && kill -0 "$cw_server_pid" 2>/dev/null; then
      kill "$cw_server_pid" 2>/dev/null
      local waited=0
      while kill -0 "$cw_server_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
      kill -0 "$cw_server_pid" 2>/dev/null && kill -9 "$cw_server_pid" 2>/dev/null
      wait "$cw_server_pid" 2>/dev/null
    fi
    rm -f "$cw_server_log"
  }
  trap cw_cleanup EXIT INT TERM

  (cd "$server_pkg" && exec env PORT="$port" "$dart" run bin/server.dart) \
    >"$cw_server_log" 2>&1 &
  cw_server_pid=$!

  local health_ok=0 waited_ms=0
  while [ "$waited_ms" -lt 30000 ]; do
    if ! kill -0 "$cw_server_pid" 2>/dev/null; then
      echo "server process exited before it ever answered /health; its output:"
      sed 's/^/     /' "$cw_server_log"
      return 1
    fi
    if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$port/health" 2>/dev/null; then
      health_ok=1
      break
    fi
    sleep 0.2
    waited_ms=$((waited_ms + 200))
  done

  if [ "$health_ok" -ne 1 ]; then
    echo "server on 127.0.0.1:$port never answered /health within 30s; its output:"
    sed 's/^/     /' "$cw_server_log"
    return 1
  fi

  # wire_smoke.dart bounds each scenario at its own --timeout-seconds
  # (default 240, left at that default here); this outer `timeout` is a
  # second, independent bound, the same relationship gate_simulator's outer
  # timeout has to the simulator's own --timeout-seconds. 420s: measured on
  # this box against a local server, both scenarios together finish in well
  # under two minutes, and 420 leaves room for a loaded 2-vCPU host without
  # ever letting a genuine hang run forever. -k gives it 10s past the TERM
  # before a KILL.
  local wire_out wire_rc
  wire_out="$(cd "$client_pkg" && timeout -k 10 420 "$client_dart" run tool/wire_smoke.dart \
    --target "ws://127.0.0.1:$port" --scenario all 2>&1)"
  wire_rc=$?

  echo "$wire_out"

  local wire_passed wire_failed wire_total
  wire_passed="$(printf '%s\n' "$wire_out" | grep -c '^PASS ' || true)"
  wire_failed="$(printf '%s\n' "$wire_out" | grep -c '^FAIL ' || true)"
  wire_total=$((wire_passed + wire_failed))
  echo "client_wire($wire_passed/$wire_total)"

  if [ "$wire_rc" -eq 124 ]; then
    echo "wire_smoke.dart did not finish within this gate's own 420s wall-clock bound"
    return 1
  fi

  # A tool that exited 0 but printed no PASS line at all checked nothing --
  # the same refusal gate_client_static makes at :214-217 for analysing
  # nothing, applied here to a run that scenario-selected nothing.
  if [ "$wire_total" -eq 0 ]; then
    echo "wire_smoke.dart printed no PASS or FAIL line at all -- refusing to report a pass for a run that exercised zero scenarios"
    return 1
  fi

  [ "$wire_rc" -eq 0 ] && return 0
  return 1
}

# 6. A real build artifact. "It compiles" is not the gate: something has to
# actually be built, not merely type-checked.
#
# The client half of this is already covered elsewhere: the `client` job in
# .github/workflows/verify.yml builds the release app bundle (and, when the
# upload-signing secrets are configured, signs and verifies it) on every
# push. That needs a Flutter toolchain this script does not assume is present,
# so it is not repeated here.
#
# What this gate checks is the other artifact: the server image. It only
# passes if it can actually run `docker build` against
# packages/ludo_server/Dockerfile from $ROOT, the same command
# deploy/ludo/deploy.sh runs and the server-image job in
# .github/workflows/verify.yml runs on every push. `command -v docker` alone
# proves nothing -- a docker client binary with no reachable daemon behind it
# is common on a bare build host -- so the check is `docker info`, which
# actually talks to the daemon.
gate_artifact() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "no docker on PATH here, so this gate cannot build the server image; it runs on every push instead, as the server-image job in .github/workflows/verify.yml"
    return 77
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "docker is on PATH but no docker daemon answered 'docker info', so this gate cannot build the server image; it runs on every push instead, as the server-image job in .github/workflows/verify.yml"
    return 77
  fi

  local log rc
  log="$(docker build -f "$ROOT/packages/ludo_server/Dockerfile" -t ludo-server:verify "$ROOT" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "docker build -f packages/ludo_server/Dockerfile -t ludo-server:verify $ROOT failed (exit $rc); last 30 lines:"
    printf '%s\n' "$log" | tail -n 30
    return 1
  fi
  echo "docker build -f packages/ludo_server/Dockerfile -t ludo-server:verify $ROOT succeeded"
  return 0
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

# With no arguments every gate below runs, in the order it always has. Named
# on the command line, only those gates run -- this is what lets CI ask for
# exactly one gate (the client job runs `bash bin/ludo-verify.sh client_wire`)
# without duplicating the server-start-and-poll machinery any gate needs.
# An unknown name is refused outright, before anything runs: a typo that
# silently ran zero gates and still printed a green summary would be exactly
# the failure this harness exists to prevent.
GATE_NAMES="specs secrets static client_static purity rules golden dice server protocol simulator client_wire artifact"
GATE_ARGS=("$@")

if [ "${#GATE_ARGS[@]}" -gt 0 ]; then
  for gate_arg in "${GATE_ARGS[@]}"; do
    case " $GATE_NAMES " in
      *" $gate_arg "*) ;;
      *)
        echo "unknown gate name: $gate_arg"
        echo "valid gate names: $GATE_NAMES"
        exit 2
        ;;
    esac
  done
fi

want_gate() {
  local name="$1"
  [ "${#GATE_ARGS[@]}" -eq 0 ] && return 0
  local g
  for g in "${GATE_ARGS[@]}"; do
    [ "$g" = "$name" ] && return 0
  done
  return 1
}

echo "ludo-verify  $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'no git')"
echo

want_gate specs         && run_gate specs         gate_specs
want_gate secrets       && run_gate secrets       gate_secrets
want_gate static        && run_gate static        gate_static
want_gate client_static && run_gate client_static gate_client_static
want_gate purity        && run_gate purity        gate_purity
want_gate rules         && run_gate rules         gate_rules
want_gate golden        && run_gate golden        gate_golden
want_gate dice          && run_gate dice          gate_dice
want_gate server        && run_gate server        gate_server
want_gate protocol      && run_gate protocol      gate_protocol
want_gate simulator     && run_gate simulator     gate_simulator
want_gate client_wire   && run_gate client_wire   gate_client_wire
want_gate artifact      && run_gate artifact      gate_artifact

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
