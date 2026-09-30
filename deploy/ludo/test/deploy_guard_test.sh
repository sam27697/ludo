#!/usr/bin/env bash
# Tests the live-room deploy guard specified for deploy/ludo/deploy.sh
# (order 221 / order 220, run 64). This test is written from that spec, not
# from whatever deploy.sh happens to do -- it is expected to fail against a
# deploy.sh that has no guard yet and to pass once the guard described below
# has been added.
#
# Usage:
#   bash deploy/ludo/test/deploy_guard_test.sh [path/to/deploy.sh]
#
# With no argument it tests the deploy.sh one directory up from this script.
# Runs correctly from any working directory.
#
# How it works: each case gets its own throwaway sandbox (mktemp -d) laid
# out like a $LUDO_ROOT (staging/.env, production/.env, repo/.git), with a
# sandbox bin/ prepended to PATH holding stand-ins for git, docker and curl.
# The stand-ins never touch anything real: they log their argv and return a
# scripted result. "git fetch" (deploy.sh's first git command) always exits
# 1 in the stand-in, so a case that gets past the guard stops right there --
# a non-empty git log is the proof the guard let it through; an empty git
# and docker log is the proof the guard refused before running anything.
#
# This deliberately does not use "set -e": most of what follows is
# intentional conditional checking of case outcomes, and a set -e script
# that runs many independent assertions is more trouble than it is worth.
# "set -u" stays on to catch typos in variable names.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH_ARG="${1:-$SCRIPT_DIR/../deploy.sh}"

if [[ ! -f "$DEPLOY_SH_ARG" ]]; then
  printf 'deploy_guard_test.sh: no such file: %s\n' "$DEPLOY_SH_ARG" >&2
  exit 2
fi
DEPLOY_SH="$(cd "$(dirname "$DEPLOY_SH_ARG")" && pwd)/$(basename "$DEPLOY_SH_ARG")"

ORIG_PATH="$PATH"
TOLERANCE_SECONDS=3

PASS_COUNT=0
FAIL_COUNT=0

DEPLOY_OUTPUT=""
DEPLOY_EXIT=0
DEPLOY_ELAPSED_S=0

SANDBOXES=()
CURRENT_SANDBOX=""

cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
  done
}
trap cleanup EXIT

# ---- sandbox and stub plumbing -------------------------------------------

write_stubs() {
  local sandbox="$1"

  # Appends full argv to the call log and exits 0, except for a "fetch"
  # argument, which is logged and then made to fail: deploy.sh's own
  # set -e then stops the script right there, so "reached git fetch" is
  # the sandbox's proof a case got past the guard.
  cat > "$sandbox/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/git.log"
for arg in "$@"; do
  if [[ "$arg" == "fetch" ]]; then
    exit 1
  fi
done
exit 0
STUB
  chmod +x "$sandbox/bin/git"

  cat > "$sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/docker.log"
exit 0
STUB
  chmod +x "$sandbox/bin/docker"

  # Logs argv. A call carrying -w is the existing readiness-poll call
  # (curl -s -o /dev/null -w '%{http_code}' ...) and always answers 200.
  # Any other call is the guard's own body fetch: it fails with exit 7 if
  # a sandbox file "curl_fail" is present, otherwise it prints the sandbox
  # file "health_body" verbatim.
  cat > "$sandbox/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/curl.log"
for arg in "$@"; do
  if [[ "$arg" == "-w" ]]; then
    printf '200'
    exit 0
  fi
done
if [[ -f "$SANDBOX/curl_fail" ]]; then
  exit 7
fi
cat "$SANDBOX/health_body" 2>/dev/null
exit 0
STUB
  chmod +x "$sandbox/bin/curl"
}

# Creates a fresh sandbox, registers it for cleanup, and leaves its path in
# CURRENT_SANDBOX. Not itself run through command substitution, since a
# function that appended to SANDBOXES from inside a subshell would not be
# able to make that append visible to the caller.
make_sandbox() {
  local sandbox
  sandbox="$(mktemp -d)"
  SANDBOXES+=("$sandbox")
  mkdir -p "$sandbox/staging" "$sandbox/production" "$sandbox/repo/.git" "$sandbox/bin"
  : > "$sandbox/staging/.env"
  : > "$sandbox/production/.env"
  : > "$sandbox/git.log"
  : > "$sandbox/docker.log"
  : > "$sandbox/curl.log"
  write_stubs "$sandbox"
  CURRENT_SANDBOX="$sandbox"
}

# Runs deploy.sh against the given sandbox under a timeout, with the given
# KEY=VALUE pairs exported first. Leaves the result in DEPLOY_OUTPUT
# (combined stdout+stderr) and DEPLOY_EXIT. A value of the empty string
# (e.g. "LUDO_DEPLOY_WAIT_SECONDS=") exports the variable as empty, which is
# different from leaving it unset.
run_deploy() {
  local sandbox="$1" timeout_s="$2"
  shift 2
  local out rc
  out="$(
    export PATH="$sandbox/bin:$ORIG_PATH"
    export SANDBOX="$sandbox"
    export LUDO_ROOT="$sandbox"
    for kv in "$@"; do
      export "$kv"
    done
    cd "$sandbox" && timeout -k 5 "$timeout_s" bash "$DEPLOY_SH" 2>&1
  )"
  rc=$?
  DEPLOY_OUTPUT="$out"
  DEPLOY_EXIT="$rc"
}

timed_run_deploy() {
  local sandbox="$1" timeout_s="$2"
  shift 2
  local start end
  start="$(date +%s%N)"
  run_deploy "$sandbox" "$timeout_s" "$@"
  end="$(date +%s%N)"
  DEPLOY_ELAPSED_S=$(( (end - start) / 1000000000 ))
}

# ---- assertion helpers -----------------------------------------------------

output_has() {
  [[ "$DEPLOY_OUTPUT" == *"$1"* ]]
}

output_has_line_prefix() {
  local prefix="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$prefix"* ]] && return 0
  done <<< "$DEPLOY_OUTPUT"
  return 1
}

output_has_exact_line() {
  local target="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$target" ]] && return 0
  done <<< "$DEPLOY_OUTPUT"
  return 1
}

# Bash-regex extraction of the N in "live_rooms=N", used where a case needs
# to check the exact number read rather than just a substring (substring
# checks for "live_rooms=1" would wrongly also match "live_rooms=12").
extract_live_rooms_n() {
  local regex='live_rooms=([0-9]+)'
  if [[ "$DEPLOY_OUTPUT" =~ $regex ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

curl_log_has_substr() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] || return 1
  grep -F -q -- "$needle" "$file"
}

curl_log_has_token() {
  local file="$1" token="$2" line tok
  [[ -f "$file" ]] || return 1
  while IFS= read -r line; do
    for tok in $line; do
      [[ "$tok" == "$token" ]] && return 0
    done
  done < "$file"
  return 1
}

reached_git_fetch() {
  local sandbox="$1"
  [[ -s "$sandbox/git.log" ]] && grep -q 'fetch' "$sandbox/git.log"
}

log_empty() {
  [[ ! -s "$1" ]]
}

pass_case() {
  printf 'PASS %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail_case() {
  local name="$1" why="$2"
  printf 'FAIL %s: %s\n' "$name" "$why"
  printf -- '--- deploy.sh output for %s ---\n' "$name"
  printf '%s\n' "$DEPLOY_OUTPUT"
  printf -- '--- end output ---\n'
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

finish_case() {
  local name="$1" why="$2"
  if [[ -z "$why" ]]; then
    pass_case "$name"
  else
    fail_case "$name" "$why"
  fi
}

# ---- cases -----------------------------------------------------------------
# Numbers in names line up with the "Cases, at minimum" list in order 221/220.

# Case 1 (S5d): rooms > 0, no knobs -- refuse before touching git or docker.
case_01_refuse_no_knobs() {
  local name="01_refuse_no_knobs"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":2}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_line_prefix "deploy.sh: refusing: live_rooms=2" \
    || why+="no line starts with 'deploy.sh: refusing: live_rooms=2'. "
  output_has "nothing changed" || why+="missing 'nothing changed'. "
  output_has "LUDO_DEPLOY_WAIT_SECONDS" || why+="missing mention of LUDO_DEPLOY_WAIT_SECONDS. "
  output_has "LUDO_DEPLOY_FORCE=1" || why+="missing mention of LUDO_DEPLOY_FORCE=1. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "

  finish_case "$name" "$why"
}

# Case 2 (S5c): rooms > 0, LUDO_DEPLOY_FORCE=1 -- proceeds, names the force.
case_02_force_proceeds() {
  local name="02_force_proceeds"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":2}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_DEPLOY_FORCE=1"

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch (git.log: $(cat "$sandbox/git.log" 2>/dev/null)). "
  output_has "live_rooms=2 forced by LUDO_DEPLOY_FORCE=1" \
    || why+="missing 'live_rooms=2 forced by LUDO_DEPLOY_FORCE=1'. "

  finish_case "$name" "$why"
}

# Case 3 (S5b, S3, S6): rooms=0 -- proceeds with a plain live_rooms=0, and
# the guard's own curl call is well formed and hits the staging port.
case_03_rooms_zero_immediate() {
  local name="03_rooms_zero_immediate"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  output_has "live_rooms=0" || why+="missing 'live_rooms=0'. "
  ! output_has "live_rooms=0 after waiting" \
    || why+="got the after-waiting message for an immediate read (no wait was ever set). "
  curl_log_has_token "$sandbox/curl.log" "-s" || why+="guard curl call is missing -s. "
  curl_log_has_substr "$sandbox/curl.log" "--max-time 5" || why+="guard curl call is missing --max-time 5. "
  curl_log_has_substr "$sandbox/curl.log" "127.0.0.1:8199/health" \
    || why+="guard curl call did not target 127.0.0.1:8199/health for staging. "
  ! curl_log_has_token "$sandbox/curl.log" "-o" || why+="guard curl call included -o. "
  ! curl_log_has_token "$sandbox/curl.log" "-w" || why+="guard curl call included -w. "

  finish_case "$name" "$why"
}

# Case 4 (S5a): curl exits non-zero -- treated as unknown, proceeds.
case_04_curl_fails_unknown() {
  local name="04_curl_fails_unknown"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  : > "$sandbox/curl_fail"

  timed_run_deploy "$sandbox" 10

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  output_has "live_rooms=unknown" || why+="missing 'live_rooms=unknown'. "

  finish_case "$name" "$why"
}

# Case 5 (S5a): body has no rooms field -- treated as unknown, proceeds.
case_05_body_no_rooms_unknown() {
  local name="05_body_no_rooms_unknown"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x"}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  output_has "live_rooms=unknown" || why+="missing 'live_rooms=unknown'. "

  finish_case "$name" "$why"
}

# Case 6 (S5e, first branch): rooms=1 dropping to 0 partway through the
# wait window -- proceeds once it sees 0, well inside the window.
case_06_wait_then_zero() {
  local name="06_wait_then_zero"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":1}' > "$sandbox/health_body"

  ( sleep 2; printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body" ) &
  local bgpid=$!

  timed_run_deploy "$sandbox" 30 "LUDO_DEPLOY_WAIT_SECONDS=20" "LUDO_DEPLOY_POLL_SECONDS=1"

  wait "$bgpid" 2>/dev/null || true

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  output_has "live_rooms=0 after waiting" || why+="missing 'live_rooms=0 after waiting'. "
  if [[ "$DEPLOY_ELAPSED_S" -ge 20 ]]; then
    why+="took ${DEPLOY_ELAPSED_S}s, expected well under the 20s wait window once the count dropped to 0. "
  fi

  finish_case "$name" "$why"
}

# Case 7 (S5e, second branch): rooms=1 for the whole window -- refuses once
# LUDO_DEPLOY_WAIT_SECONDS elapses, within WAIT + POLL + tolerance.
case_07_wait_timeout_refuse() {
  local name="07_wait_timeout_refuse"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":1}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 20 "LUDO_DEPLOY_WAIT_SECONDS=3" "LUDO_DEPLOY_POLL_SECONDS=1"

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_line_prefix "deploy.sh: refusing: live_rooms=1 after waiting" \
    || why+="no line starts with 'deploy.sh: refusing: live_rooms=1 after waiting'. "
  output_has "nothing changed" || why+="missing 'nothing changed'. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "
  local max_allowed=$((3 + 1 + TOLERANCE_SECONDS))
  if [[ "$DEPLOY_ELAPSED_S" -gt "$max_allowed" ]]; then
    why+="took ${DEPLOY_ELAPSED_S}s, expected at most WAIT(3) + POLL(1) + ${TOLERANCE_SECONDS}s tolerance = ${max_allowed}s. "
  fi

  finish_case "$name" "$why"
}

# Case 8, first half (S4): LUDO_DEPLOY_WAIT_SECONDS=abc fails at once with
# the exact message, before any git or docker call.
case_08a_wait_seconds_invalid_abc() {
  local name="08a_wait_seconds_invalid_abc"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_DEPLOY_WAIT_SECONDS=abc"

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_exact_line "deploy.sh: LUDO_DEPLOY_WAIT_SECONDS must be a positive integer" \
    || why+="no output line is exactly 'deploy.sh: LUDO_DEPLOY_WAIT_SECONDS must be a positive integer'. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "

  finish_case "$name" "$why"
}

# Case 8, second half (S4): same for LUDO_DEPLOY_POLL_SECONDS=0 (zero is not
# positive).
case_08b_poll_seconds_invalid_zero() {
  local name="08b_poll_seconds_invalid_zero"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_DEPLOY_POLL_SECONDS=0"

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_exact_line "deploy.sh: LUDO_DEPLOY_POLL_SECONDS must be a positive integer" \
    || why+="no output line is exactly 'deploy.sh: LUDO_DEPLOY_POLL_SECONDS must be a positive integer'. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "

  finish_case "$name" "$why"
}

# Extra, implied by S4: a negative value is not a positive integer either.
case_08c_wait_seconds_invalid_negative() {
  local name="08c_wait_seconds_invalid_negative"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_DEPLOY_WAIT_SECONDS=-5"

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_exact_line "deploy.sh: LUDO_DEPLOY_WAIT_SECONDS must be a positive integer" \
    || why+="no output line is exactly 'deploy.sh: LUDO_DEPLOY_WAIT_SECONDS must be a positive integer'. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "

  finish_case "$name" "$why"
}

# Extra, implied by S4's parenthetical: an empty LUDO_DEPLOY_WAIT_SECONDS
# counts as unset, not as invalid input, so rooms > 0 with no force falls
# straight through to the plain no-wait refusal of case 1.
case_08d_wait_seconds_empty_counts_as_unset() {
  local name="08d_wait_seconds_empty_counts_as_unset"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":2}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_DEPLOY_WAIT_SECONDS="

  local why=""
  ! output_has "must be a positive integer" \
    || why+="an empty LUDO_DEPLOY_WAIT_SECONDS was treated as invalid input instead of unset. "
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit (rooms=2, no wait, no force), got 0. "
  output_has_line_prefix "deploy.sh: refusing: live_rooms=2" \
    || why+="missing the plain no-wait refusal line for live_rooms=2. "
  ! output_has "after waiting" \
    || why+="entered the waiting branch even though LUDO_DEPLOY_WAIT_SECONDS was empty. "
  log_empty "$sandbox/git.log" || why+="git.log not empty. "

  finish_case "$name" "$why"
}

# Case 9 (S5, last line): force and wait both set -- force wins, no sleep.
case_09_force_wins_over_wait() {
  local name="09_force_wins_over_wait"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":3}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 15 "LUDO_DEPLOY_FORCE=1" "LUDO_DEPLOY_WAIT_SECONDS=20" "LUDO_DEPLOY_POLL_SECONDS=1"

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  output_has "live_rooms=3 forced by LUDO_DEPLOY_FORCE=1" \
    || why+="missing 'live_rooms=3 forced by LUDO_DEPLOY_FORCE=1'. "
  if [[ "$DEPLOY_ELAPSED_S" -ge 5 ]]; then
    why+="took ${DEPLOY_ELAPSED_S}s; force should proceed immediately without entering the wait loop. "
  fi

  finish_case "$name" "$why"
}

# Case 10 (S3, S6): production targets 8099, with -s and --max-time 5.
# (Case 3 above already checks the staging target is 8199.)
case_10_production_port_targeting() {
  local name="10_production_port_targeting"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":0}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10 "LUDO_ENVIRONMENT=production"

  local why=""
  reached_git_fetch "$sandbox" || why+="did not reach git fetch. "
  curl_log_has_substr "$sandbox/curl.log" "127.0.0.1:8099/health" \
    || why+="guard curl call did not target 127.0.0.1:8099/health for production. "
  curl_log_has_token "$sandbox/curl.log" "-s" || why+="guard curl call is missing -s. "
  curl_log_has_substr "$sandbox/curl.log" "--max-time 5" || why+="guard curl call is missing --max-time 5. "

  finish_case "$name" "$why"
}

# Case 11 (S3): a realistic body with other numeric fields around rooms --
# the extraction must not grab uptime_s or any other number instead.
case_11_realistic_body_extracts_correct_field() {
  local name="11_realistic_body_extracts_correct_field"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"a121418","uptime_s":30462,"rooms":12}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has_line_prefix "deploy.sh: refusing: live_rooms=12" \
    || why+="no line starts with 'deploy.sh: refusing: live_rooms=12'. "
  local n
  n="$(extract_live_rooms_n)" || n=""
  if [[ "$n" != "12" ]]; then
    why+="parsed live_rooms as '${n:-<none>}' instead of 12 (body also has uptime_s=30462 -- a naive parser can grab the wrong number). "
  fi

  finish_case "$name" "$why"
}

# Extra, implied by S2: the guard must sit after the existing checkout
# check, not before it -- a missing checkout still fails with the existing
# message, and the guard's curl never runs.
case_12_missing_checkout_before_guard() {
  local name="12_missing_checkout_before_guard"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  rm -rf "$sandbox/repo/.git"
  printf '{"status":"ok","version":"x","rooms":2}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 10

  local why=""
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit, got 0. "
  output_has "no checkout at" \
    || why+="missing the existing 'no checkout at' failure message -- the guard must not run before this check. "
  log_empty "$sandbox/curl.log" \
    || why+="curl.log not empty -- the guard ran its health check before the existing checkout check. "
  log_empty "$sandbox/git.log" || why+="git.log not empty: $(tr '\n' '|' < "$sandbox/git.log"). "
  log_empty "$sandbox/docker.log" || why+="docker.log not empty: $(tr '\n' '|' < "$sandbox/docker.log"). "

  finish_case "$name" "$why"
}

# Extra, implied by S4: LUDO_DEPLOY_POLL_SECONDS left unset (here, set to
# empty, which per S4 counts as unset) must fall back to the stated default
# of 30 seconds, not to something quicker to test. Slow by design: this is
# the only way to prove the 30 second number itself rather than assuming it.
case_13_default_poll_seconds_applied() {
  local name="13_default_poll_seconds_applied"
  make_sandbox
  local sandbox="$CURRENT_SANDBOX"
  printf '{"status":"ok","version":"x","rooms":1}' > "$sandbox/health_body"

  timed_run_deploy "$sandbox" 60 "LUDO_DEPLOY_WAIT_SECONDS=1" "LUDO_DEPLOY_POLL_SECONDS="

  local why=""
  ! output_has "must be a positive integer" \
    || why+="an empty LUDO_DEPLOY_POLL_SECONDS was treated as invalid input instead of unset. "
  [[ "$DEPLOY_EXIT" -ne 0 ]] || why+="expected non-zero exit (rooms stayed at 1 for the whole wait), got 0. "
  output_has_line_prefix "deploy.sh: refusing: live_rooms=1 after waiting" \
    || why+="missing the after-waiting refusal line. "
  if [[ "$DEPLOY_ELAPSED_S" -lt 25 ]]; then
    why+="took only ${DEPLOY_ELAPSED_S}s; with LUDO_DEPLOY_POLL_SECONDS unset the default poll interval is 30s, so a single poll cycle should take about that long. "
  fi
  if [[ "$DEPLOY_ELAPSED_S" -gt 45 ]]; then
    why+="took ${DEPLOY_ELAPSED_S}s, far more than WAIT(1) + default POLL(30) plus a generous tolerance. "
  fi

  finish_case "$name" "$why"
}

main() {
  case_01_refuse_no_knobs
  case_02_force_proceeds
  case_03_rooms_zero_immediate
  case_04_curl_fails_unknown
  case_05_body_no_rooms_unknown
  case_06_wait_then_zero
  case_07_wait_timeout_refuse
  case_08a_wait_seconds_invalid_abc
  case_08b_poll_seconds_invalid_zero
  case_08c_wait_seconds_invalid_negative
  case_08d_wait_seconds_empty_counts_as_unset
  case_09_force_wins_over_wait
  case_10_production_port_targeting
  case_11_realistic_body_extracts_correct_field
  case_12_missing_checkout_before_guard
  case_13_default_poll_seconds_applied

  printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main
