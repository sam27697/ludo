# Templates

Copy a template, then replace every `<...>`. Keep key names and table headers exactly as written: the runner and the gate tools read them.

## STATE.md

```
PROGRAM_STATUS: RUNNING
SCHEDULE_ROW: 1
ROUND: 1
TRACK: A
CYCLE: 1
STEP: 1
SUBSTEP: start
NEXT_ACTION: create ux/A-c1 from ux/program and start Step 1
WAITING_FOR: NONE
BRANCH: ux/A-c1
CYCLE_BASE: <commit>
UPDATED: <ISO 8601 UTC time>

## Schedule
| Row | Round | Track | Cycle | Status | Closed | Tag |
|---|---|---|---|---|---|---|
| 1 | 1 | A | 1 | IN-PROGRESS | | |
| 2 | 1 | B | 1 | TODO | | |
| 3 | 1 | C | 1 | TODO | | |
| 4 | 1 | D | 1 | TODO | | |
| 5 | 2 | A | 2 | TODO | | |
| 6 | 2 | B | 2 | TODO | | |
| 7 | 2 | C | 2 | TODO | | |
| 8 | 2 | D | 2 | TODO | | |
| 9 | 3 | A | 3 | TODO | | |
| 10 | 3 | B | 3 | TODO | | |
| 11 | 3 | C | 3 | TODO | | |
| 12 | 3 | D | 3 | TODO | | |
| F | F | ALL | F | TODO | | |

Status values: TODO, IN-PROGRESS, CLOSED, NOT-NEEDED, ESCALATED.

## Open notes (latest review of the current cycle)
S0: 0 | S1: 0 | S2: 0 | S3: 0

## Escalations
none
```

## HANDOFF.md (rewritten at every close, at most 150 lines)

```
# Handoff after <X><n>, <date>
NEXT: row <n>, track <X>, cycle <n>

## What changed (one line per task, with its commit)
## Metrics now against baseline and best
| Metric | Baseline | Best | Now |
|---|---|---|---|
## Weak areas that remain
## Ideas carried forward (top 5 from backlog_ideas.md by score)
## Traps: what failed and why
## Claims to verify next session (at least 3, each checkable in the running app)
```

## facts.md

```
PROJECT_ROOT: <path>
DEFAULT_BRANCH: <name>
BASE_REV: <commit>
PYTHON: python | python3
NODE: <version or none>
STACK: <frameworks, languages, component library, styling, state, i18n>
PLATFORMS: <detected>
BUILD: <command>
RUN: <command and URL or device>
LINT: <command>
TEST: <command>
TEST_TOOLING_ADDED: <packages or none, with decision record id>
GIT_IDENTITY: <name and email, human>
CORE_GOALS: <list, CONFIGURED or DETECTED>

## Capability probe
| Capability | Result | Evidence |
|---|---|---|

## Detected config values
| Key | Value | Source |
|---|---|---|
```

## flows.md

```
# Core goal flows (input for effort_calc.py)
FLOW: <id> | <goal in plain words, from where to where>
STEPS: <operators: T G K*n M H W:x N>
```

## baseline.md and metrics.md

```
## <baseline | X><n> <date>
| Metric | Scope | Value | Best so far | Evidence |
|---|---|---|---|---|
| taps | start-match | 6 | 6 | .uxprogram/logs/<log> |
```

## 01_explore.md

```
# Explore <X><n>
## Freshness
EVIDENCE: <log> | <build id matched>
## Handoff claims checked
| Claim | CONFIRMED or WRONG | Evidence |
|---|---|---|
## Stack summary (cycle 1; later cycles list only changes)
## Screen inventory
| Route or screen | Source file | Walked | Before shots |
|---|---|---|---|
## Core goal walkthroughs
| Goal | Flow id | Taps | Decisions | Effort s | Friction | Evidence |
|---|---|---|---|---|---|---|
## Instrument results
## Pain points
| ID | Where | Pain point | Measured | Evidence | From queue |
|---|---|---|---|---|---|
## Backlog ideas re-checked
```

## Task card: tasks/T<nn>.md

`ALLOWED_PATHS` items come directly under the key, one per line, followed by a blank line. Never list acceptance check files here.

```
TASK: <X><n>-T<nn>
TITLE: <what changes, in plain words>
TYPE: task | fix | spike
ROOT_CAUSE: <root cause id and name>
NOTES_FIXED: none | <note ids, for fix tasks>
BASE_COMMIT: <filled at Step 9>
CHECKS_COMMIT: <filled after R4>
ALLOWED_PATHS:
- <glob>
- <glob>

ACCEPTANCE:
| ID | Type | Criterion (observable) | Threshold |
|---|---|---|---|
| AC1 | NEW | <what a user or instrument observes> | <number or exact condition> |
| AC2 | KEEP | <existing behavior that must stay> | <condition> |
| AC3 | HUMAN | <what only a person can judge> | human_checklist item |

METRIC_TO_MOVE: <metric, from and to>
RISK: <what could break, which T3 conditions to test>
DEPENDS_ON: none | <task ids>
ROLLBACK: <how to undo>
SPIKE_BRANCH: none | ux/spike-<X>-c<n>-<slug>
SPIKE_MEASURE: none | <what the spike must measure>
```

## Dispatch file: .uxprogram/dispatch/<ID>.md

Write every path in full from the project root. The runner adds ENGINE, AUTHOR_ENGINE, INDEPENDENCE_HINT, STARTED, FINISHED, ENGINE_EXIT, RUNNER_LOG and RESULT_NOTE.

```
DISPATCH_ID: <X><n>-S<step>-<role>[-T<nn> or -r<k>]
ROLE: R1 | R2 | R3 | R4 | R5
ROLE_FILE: .uxprogram/kit/roles/<role file>
MODE: - | AUTHOR-CHECKS | TEST-MATRIX
STATUS: PENDING
CREATED: <ISO 8601 UTC time>
OUTPUT: <path of the file the role must write>
CYCLE_FOLDER: .uxprogram/track-<X>/cycle-<n>
CYCLE_BASE: <commit>
BASE_COMMIT: <commit or ->
WRITE_SCOPE: <output only | ALLOWED_PATHS of the task card | test folders>
DO_NOT_TOUCH: <paths or none>
INPUTS:
- <path>
- <path>
INSTRUCTIONS:
- <round number, failing logs to fix, spike branch, anything specific>
```

## 08_implementation_log.md entry

```
## <task id> <title>
STATUS: ACCEPTED | ESCALATED
BASE_COMMIT: <hash>
CHECKS_COMMIT: <hash>
COMMIT: <hash>
EVIDENCE: <log> | NEW checks failed before implementation
EVIDENCE: <log> | scope of the checks commit
EVIDENCE: <log> | scope of the task commit
EVIDENCE: <log> | negative space
EVIDENCE: <log> | authorship
EVIDENCE: <log> | all acceptance checks pass
EVIDENCE: <log> | project gate
SHOTS: <after-shot folder>
DEVIATIONS: none | <what and why, with decision record id>
SPIKE_VERDICT: none | KEEP | ADAPT | DROP, <evidence>
```

## 12_rework_r<k>.md

```
# Rework <X><n> round <k>
| Note | Sev | Proposal | Reason | Fix task | Evidence |
|---|---|---|---|---|---|
| A1-N01 | S1 | FIX | send covered at scroll end | T07 | <log after the fix> |
| A1-N04 | S3 | DEFER | token work belongs to track B; copied to queue_B.md | - | - |
| A1-N05 | S2 | REJECT | measured contrast 5.2:1 passes 4.5:1 | - | <log> |
```

## 13_close.md

```
# Close <X><n>
## Summary (at most 10 lines)
## Metrics
| Metric | Baseline | Best before | Now | Ratchet | Evidence |
|---|---|---|---|---|---|
## Tasks shipped
## Spikes and verdicts
## Deferred notes and where they went
## Decisions
## Lessons
## Close gate logs
```

## decisions.md entry

```
## D-<nnn> <date> <X><n> Step <s>
DECISION: <what>
WHY: <reason, with evidence paths>
ALTERNATIVES: <options considered>
REVERSIBLE: yes | no, <how>
REVERSES: none | D-<nnn>
```

## human_decisions.md entry

```
## H-<nnn> <date> <X><n>
DEFAULT_TAKEN: <what the program did>
WHY: <reason>
TO_REVERSE: <exact steps>
```

## human_checklist.md entry

```
## HC-<nn> <title> (<X><n>)
STEPS:
1. <step>
2. <step>
EXPECTED: <result>
RESULT: <left blank for the human>
```

## queue_<X>.md item

```
- <note id> | <sev> | from <X><n> | <finding> | <evidence path>
```

## ESCALATION-<id>.md

```
# Escalation <id>
WHAT_HAPPENED: <plain words>
EVIDENCE: <log paths>
OPTIONS:
1. <option> | trade-off: <...>
2. <option> | trade-off: <...>
RECOMMENDATION: <option and why>
CONTINUING_WITH: <what the program does meanwhile>
```

## final/FINAL_REPORT.md

```
# Final report
1. Summary (at most 15 lines)
2. Metrics: baseline, after each round, final
3. Before and after screenshots of every core screen
4. Signature elements and key design decisions
5. Final principles and tokens
6. Engagement model and ethics review
7. Remaining backlog with scores: UX ideas and frozen-area ideas
8. Open human decisions and human checklist status
9. Known limits and the recommended next focus
```

## gate.sh skeleton

Every `REPLACE_ME` must become a real command at setup. A line left unreplaced fails, which is intended.

```bash
#!/usr/bin/env bash
# Project gate: runs every check even after a failure; exit 0 only when all pass.
# A check that cannot run is a failure, never a skip.
set -u
cd "$(git rev-parse --show-toplevel)" || { echo "GATE: FAIL not-a-repository"; exit 1; }
PY="${PY:-python3}"
BASE="$(cat .uxprogram/base_rev)"
failed=()
check() {
  local name="$1"; shift
  echo "=== CHECK $name: $*"
  if "$@"; then echo "=== PASS $name"; else echo "=== FAIL $name"; failed+=("$name"); fi
}
check build       bash -c 'REPLACE_ME_BUILD_COMMAND'
check lint        bash -c 'REPLACE_ME_LINT_OR_TYPECHECK_COMMAND'
check tests       bash -c 'REPLACE_ME_TEST_COMMAND_FAILING_ONLY_ON_TESTS_NOT_IN_known_failures.txt'
check ux-checks   bash -c 'REPLACE_ME_PERMANENT_UX_CHECKS_COMMAND'
check probe       bash -c 'REPLACE_ME_PROBE_OR_PLATFORM_INSTRUMENTS_ON_CORE_SCREENS'
check authorship  "$PY" .uxprogram/kit/tools/authorship_scan.py --base "$BASE"
check negative    "$PY" .uxprogram/kit/tools/negative_space.py --base "$BASE"
if [ ${#failed[@]} -eq 0 ]; then echo "GATE: PASS"; exit 0; fi
echo "GATE: FAIL ${failed[*]}"
exit 1
```

## gate.ps1 skeleton (only where bash is not available)

```powershell
# Project gate: runs every check even after a failure; exit 0 only when all pass.
# A check that cannot run is a failure, never a skip.
$ErrorActionPreference = 'Continue'
Set-Location (git rev-parse --show-toplevel)
$py = if ($env:PY) { $env:PY } else { 'python' }
$base = (Get-Content .uxprogram/base_rev -Raw).Trim()
$script:failed = @()
function Invoke-Check([string]$name, [scriptblock]$cmd) {
  Write-Output "=== CHECK $name"
  $global:LASTEXITCODE = 0
  try { & $cmd } catch { Write-Output $_; $global:LASTEXITCODE = 1 }
  if ($LASTEXITCODE -ne 0) { Write-Output "=== FAIL $name"; $script:failed += $name }
  else { Write-Output "=== PASS $name" }
}
Invoke-Check 'build'      { REPLACE_ME_BUILD_COMMAND }
Invoke-Check 'lint'       { REPLACE_ME_LINT_OR_TYPECHECK_COMMAND }
Invoke-Check 'tests'      { REPLACE_ME_TEST_COMMAND_FAILING_ONLY_ON_TESTS_NOT_IN_known_failures.txt }
Invoke-Check 'ux-checks'  { REPLACE_ME_PERMANENT_UX_CHECKS_COMMAND }
Invoke-Check 'probe'      { REPLACE_ME_PROBE_OR_PLATFORM_INSTRUMENTS_ON_CORE_SCREENS }
Invoke-Check 'authorship' { & $py .uxprogram/kit/tools/authorship_scan.py --base $base }
Invoke-Check 'negative'   { & $py .uxprogram/kit/tools/negative_space.py --base $base }
if ($script:failed.Count -eq 0) { Write-Output 'GATE: PASS'; exit 0 }
Write-Output ('GATE: FAIL ' + ($script:failed -join ' '))
exit 1
```
