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

# 1. Static analysis and formatting. First because it is free and because a
# tree that does not analyse cleanly is not worth running tests against.
gate_static() {
  local dart=""
  if command -v dart >/dev/null 2>&1; then
    dart="$(command -v dart)"
  elif [ -n "${DART_SDK:-}" ] && [ -x "$DART_SDK/bin/dart" ]; then
    dart="$DART_SDK/bin/dart"
  elif [ -x /workspace/toolchains/dart-sdk/bin/dart ]; then
    dart=/workspace/toolchains/dart-sdk/bin/dart
  fi

  if [ -z "$dart" ]; then
    echo "no Dart SDK found on PATH, in \$DART_SDK, or at /workspace/toolchains/dart-sdk"
    return 77
  fi

  local out rc
  out="$("$dart" analyze --fatal-infos --fatal-warnings "$ROOT" 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    echo "$out"
    return 1
  fi

  local fmt_out fmt_rc
  fmt_out="$("$dart" format --output=none --set-exit-if-changed "$ROOT" 2>&1)"; fmt_rc=$?
  if [ $fmt_rc -ne 0 ]; then
    echo "$fmt_out"
    return 1
  fi

  echo "$out"
  echo "$fmt_out"
  return 0
}

# 2. Rules unit tests. Every numbered rule in docs/RULES.md, plus section 7's
# list of the ones a naive implementation gets wrong.
gate_rules() {
  echo "no engine yet"
  return 77
}

# 3. The golden corpus. N complete games recorded as seed, intentions and a
# final state hash. The engine replays them and the hashes must match. A hash
# change is a defect until someone proves it was an intended rule change.
gate_golden() {
  echo "no corpus yet"
  return 77
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
run_gate rules      gate_rules
run_gate golden     gate_golden
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
