#!/usr/bin/env bash
# Runs on the CI runner against an already booted emulator (adb on PATH, one
# device). Installs a TalkBack built by build_talkback.sh, turns it on without
# any UI step, raises its log level, launches the app, waits a fixed time and
# records what TalkBack sent to text-to-speech. Order 621.
#
# Called as ONE line from .github/workflows/talkback-probe.yml, because
# android-emulator-runner hands every line of `script:` to its own `sh -c`
# (device-smoke.yml documents this at length). Everything that has to share
# state therefore lives in here, and this file does the error handling that
# device-smoke.yml does with `set +e` and explicit exit codes: no `set -e`, every
# step that can fail checks itself and calls fail(), and an EXIT trap saves the
# logs whether the script ends green, red or half way through.
#
# What the TalkBack source (commit pinned in the workflow) says, with the places
# it was read:
#   component   applicationId com.android.talkback (build.gradle) plus the
#               service class com.google.android.marvin.talkback.TalkBackService
#               (talkback/src/main/AndroidManifest.xml:73)
#   log line    SpeechControllerImpl.processNextFragmentInternal logs, at
#               VERBOSE through LogUtils.v, `Speaking fragment text="<text>",
#               utteranceId=..., ...` just before it hands the text to the TTS
#               engine (utils/.../output/SpeechControllerImpl.java:2038-2046).
#               LogUtils prefixes every tag with "talkback: " (TalkBackService
#               .java:1562), so the tag is `talkback: SpeechControllerImpl`.
#   log level   LogUtils defaults to ERROR (LogUtils.java:45). TalkBackService
#               .reloadPreferenceLogLevel (:3290) sets it from the string
#               preference `pref_log_level` (donottranslate.xml:534), where 2 is
#               VERBOSE (donottranslate.xml:733-741). It runs from
#               resumeInfrastructure (:2477), i.e. at service connect.
#   prefs file  SharedPreferencesUtils.getSharedPreferences (utils/.../
#               SharedPreferencesUtils.java:195-201) reads the DEFAULT prefs of
#               the DEVICE-PROTECTED storage context, so the file is
#               /data/user_de/0/com.android.talkback/shared_prefs/
#               com.android.talkback_preferences.xml. It is written with
#               run-as, which works because the build is a debug build.
#   first run   TalkBackService.shouldShowTutorial (:3405) is false when
#               pref_has_performed_restore_key is true; the what's-new
#               onboarding (OnboardingInitiator.showOnboardingIfNecessary) is
#               skipped when pref_update_welcome_16_2_shown_key is true; the
#               runtime permission dialogs (NotificationUtils:121,
#               CallStateMonitor:179) are skipped when POST_NOTIFICATIONS and
#               READ_PHONE_STATE are already granted.
#
# Inputs (environment):
#   OUT_DIR          directory for every file this writes (created)
#   TALKBACK_APK     path of talkback-debug.apk
#   APP_APK          path of the app apk to launch
#   APP_ID           package id of the app (default app.fayad.ludo)
#   WAIT_SECONDS     time to let the app run after launch (default 45)
#   PROBE_APK        optional, order 623: the announcement probe apk built from
#                    packages/ludo_client/probe/talkback_announce_main.dart. When
#                    set, a second phase installs it over the app (same package id,
#                    same debug signing, so adb install -r replaces it), launches
#                    it and counts how often TalkBack spoke each case. Unset, the
#                    script behaves as it did for order 621.
#   PROBE_TIMEOUT    longest wait for the probe script to report LUDO_PROBE_DONE
#                    (default 150 seconds; the script itself needs about 50)
#   PROBE_TAIL       seconds to keep recording after LUDO_PROBE_DONE (default 6)
# Exit codes: 0 TalkBack spoke at least once after the app was launched (and,
# when PROBE_APK is set, the announcement probe ran; how often each case was
# spoken is a measurement and never changes the exit code); 1 it did not, or an
# earlier step failed, or the probe never ran (the message says which).

OUT_DIR="${OUT_DIR:-probe-out}"
APP_ID="${APP_ID:-app.fayad.ludo}"
WAIT_SECONDS="${WAIT_SECONDS:-45}"
PROBE_APK="${PROBE_APK:-}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-150}"
PROBE_TAIL="${PROBE_TAIL:-6}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TB_PKG="com.android.talkback"
TB_SVC="com.google.android.marvin.talkback.TalkBackService"
TB_COMPONENT="$TB_PKG/$TB_SVC"
PREFS_DIR="/data/user_de/0/$TB_PKG/shared_prefs"
PREFS_FILE="${TB_PKG}_preferences.xml"
SPOKEN_PATTERN='Speaking fragment text='

mkdir -p "$OUT_DIR"

say() { echo "talkback-probe: $*"; }

COLLECTED=0
collect() {
  [ "$COLLECTED" -eq 0 ] || return 0
  COLLECTED=1
  say "saving logcat and device state to $OUT_DIR"
  timeout 90 adb logcat -d -v threadtime > "$OUT_DIR/logcat-full.txt" 2>&1
  timeout 30 adb shell dumpsys accessibility > "$OUT_DIR/dumpsys-accessibility.txt" 2>&1
  timeout 30 adb exec-out screencap -p > "$OUT_DIR/screen-after-launch.png" 2>/dev/null
  return 0
}

RC=0
on_exit() {
  RC=$?
  collect
  exit "$RC"
}
trap on_exit EXIT

fail() {
  echo "talkback-probe: FAILED: $*" >&2
  exit 1
}

# poll <seconds> <description> <command...>: run the command once a second until
# it succeeds or the time is up.
poll() {
  _limit="$1"; _what="$2"; shift 2
  _i=0
  while [ "$_i" -lt "$_limit" ]; do
    if "$@" >/dev/null 2>&1; then
      say "$_what: ready after ${_i}s"
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  say "$_what: not ready after ${_limit}s"
  return 1
}

# A TalkBack log line is one whose logcat TAG starts with "talkback: " (LogUtils
# prefix, see above), i.e. "... V talkback: SpeechControllerImpl: ...". A plain
# substring match on "talkback: " is wrong: it also hits "com.android.talkback:
# installer ..." from PackageManager and "ndroid.talkback: Late-enabling ..." from
# the runtime (run 42964353017 passed this wait on exactly such lines).
tb_tagged_line() { adb logcat -d 2>/dev/null | grep -qE '[VDIWEF] talkback: '; }
# The accessibility manager's own view. Section names are the ones in the dump
# artifact of run 42964353017 (Android 16 google_apis x86_64): the attribute
# "installedServiceCount=N" inside the "attributes:{...}" line, and the lines
# "     Bound services:{...}" and "     Enabled services:{...}".
a11y_dump() { adb shell dumpsys accessibility 2>/dev/null | tr -d '\r'; }
installed_count() { a11y_dump | sed -n 's/.*installedServiceCount=\([0-9][0-9]*\).*/\1/p' | head -n 1; }
installed_count_grew() { _c="$(installed_count)"; [ -n "$_c" ] && [ "$_c" -gt "$BASE_COUNT" ]; }
# Bound means all three of these hold in one dump (run 42966781170 showed that
# Android 16 prints the service LABEL on the Bound line, not the component):
#   - the "Enabled services:" line holds the component name;
#   - the "Bound services:" line is not "{}" and holds "label=TalkBack". The label
#     is the TalkBack build's own: the manifest gives the service
#     android:label="@string/talkback_title" (talkback/src/main/AndroidManifest.xml:75)
#     and talkback/src/main/res/values/strings.xml:6 defines it as TalkBack_TfP;
#   - the attributes line says touchExplorationEnabled=true, which TalkBack
#     requests from the system when it connects.
tb_bound() {
  _dump="$(a11y_dump)"
  printf '%s\n' "$_dump" | grep -F 'Enabled services:' | grep -qF "$TB_COMPONENT" || return 1
  _bound="$(printf '%s\n' "$_dump" | grep -F 'Bound services:' | head -n 1)"
  case "$_bound" in
    *'Bound services:{}'*) return 1 ;;
    *label=TalkBack*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_dump" | grep -qF 'touchExplorationEnabled=true'
}
tb_enabled_setting() { adb shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r' | grep -qF "$TB_COMPONENT"; }
show_a11y_state() {
  say "  enabled_accessibility_services = $(adb shell settings get secure enabled_accessibility_services | tr -d '\r')"
  say "  accessibility_enabled = $(adb shell settings get secure accessibility_enabled | tr -d '\r')"
  a11y_dump | grep -E 'installedServiceCount|Bound services:|Enabled services:|Binding services:|Crashed services:' | sed 's/^ */talkback-probe:   /' | cut -c1-400
}
spoke_any() { adb logcat -d 2>/dev/null | grep -F 'SpeechControllerImpl' | grep -qF -- "$SPOKEN_PATTERN"; }
tb_running() { [ -n "$(adb shell pidof "$TB_PKG" 2>/dev/null | tr -d '\r')" ]; }

[ -f "$TALKBACK_APK" ] || fail "TALKBACK_APK is not a file: $TALKBACK_APK"
[ -f "$APP_APK" ] || fail "APP_APK is not a file: $APP_APK"

say "step 1: the device"
adb devices -l
adb wait-for-device
poll 120 "boot completed" sh -c '[ "$(adb shell getprop sys.boot_completed | tr -d "\r")" = "1" ]' || fail "device did not report boot completed"
say "api level $(adb shell getprop ro.build.version.sdk | tr -d '\r'), abi list $(adb shell getprop ro.product.cpu.abilist | tr -d '\r'), build $(adb shell getprop ro.build.fingerprint | tr -d '\r')"

say "step 2: keep the screen on and unlocked (TalkBack drops events while the screen is off)"
adb shell svc power stayon true
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard

say "step 3: enlarge the logcat ring buffer so TalkBack's verbose output is not overwritten"
adb logcat -G 64M || say "could not enlarge the logcat buffer, continuing with the default"
adb logcat -g
adb logcat -c

say "step 4: installing TalkBack ($TALKBACK_APK)"
BASE_COUNT="$(installed_count)"
say "accessibility manager installedServiceCount before the install: ${BASE_COUNT:-unreadable}"
# -g grants every runtime permission named in the manifest, -i sets the installer
# to the Play Store package name. Both are belt and braces: the log of run
# 42964353017 shows TalkBack was started as a service without them.
adb install -r -t -g -i com.android.vending "$TALKBACK_APK" || fail "adb install of TalkBack failed (INSTALL_FAILED_NO_MATCHING_ABIS means the APK has no x86_64 libraries)"
adb shell pm path "$TB_PKG" | grep -q '^package:' || fail "$TB_PKG is not installed after adb install"
if adb shell cmd package query-services --brief -a android.accessibilityservice.AccessibilityService | tr -d '\r' | grep -qF "$TB_COMPONENT"; then
  say "package manager lists $TB_COMPONENT as an accessibility service"
else
  say "package manager did not list $TB_COMPONENT; the waits below decide"
fi
# The package manager knowing the service proves nothing about the accessibility
# manager, which learns of it through its own package monitor a little later.
# Its dump has no per-service list of installed services on this image, only the
# count, so the key is: the count is greater than it was before the install.
if [ -n "$BASE_COUNT" ]; then
  say "waiting for the accessibility manager to count the new service (installedServiceCount > $BASE_COUNT)"
  poll 60 "accessibility manager sees the installed TalkBack service" installed_count_grew || say "installedServiceCount is still $(installed_count); continuing, the bind wait below is the real check"
else
  say "installedServiceCount could not be read from dumpsys accessibility; skipping the installed-service wait"
fi
# Let the broadcasts the install queued (PACKAGE_ADDED and friends) drain, so a
# late delivery cannot land after the enable write below. Not every image has
# this am subcommand, so a failure only prints.
timeout 60 adb shell am wait-for-broadcast-idle || say "am wait-for-broadcast-idle did not complete (older am, or timed out); continuing"

say "step 5: granting the runtime permissions TalkBack would otherwise ask for with a dialog"
for perm in android.permission.POST_NOTIFICATIONS android.permission.READ_PHONE_STATE android.permission.RECORD_AUDIO; do
  if adb shell pm grant "$TB_PKG" "$perm"; then say "granted $perm"; else say "could not grant $perm (not fatal; a dialog may appear)"; fi
done
# Sideloaded accessibility services can be blocked as "restricted settings" on
# Android 13+. Not needed on the run that failed (the service was started), kept
# because it costs nothing.
adb shell appops set "$TB_PKG" ACCESS_RESTRICTED_SETTINGS allow || say "appops set ACCESS_RESTRICTED_SETTINGS failed (not fatal)"

say "step 6: writing TalkBack's preferences (log level VERBOSE, first-run screens off) with run-as"
# No am force-stop here. The first version of this script force-stopped the
# package at this point, and the system delivered the resulting
# PACKAGE_RESTARTED broadcast to the accessibility manager only AFTER the enable
# write of step 7 (run 42964353017: force stop 05:24:59.431, enable write
# 05:24:59.648, PACKAGE_RESTARTED seen by AppWidgetService 05:25:00.617,
# enabled_accessibility_services rewritten behind our back 05:25:01.077). The
# accessibility manager treats a force stop of a package as "the user turned
# that service off" and removes it from the enabled list. A freshly installed
# package has no process to stop, so only a running one is handled, and then
# with a drain afterwards.
if tb_running; then
  say "TalkBack is already running; stopping it so it re-reads its preferences"
  adb shell am force-stop "$TB_PKG"
  timeout 60 adb shell am wait-for-broadcast-idle || say "am wait-for-broadcast-idle did not complete; sleeping 10s instead"
  sleep 10
else
  say "TalkBack has no process, nothing to stop"
fi
PREFS_XML="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name=\"pref_log_level\">2</string>
    <boolean name=\"pref_has_performed_restore_key\" value=\"true\" />
    <boolean name=\"first_time_user\" value=\"false\" />
    <boolean name=\"has_training_exit\" value=\"true\" />
    <boolean name=\"has_onboarding_exit\" value=\"true\" />
    <boolean name=\"pref_update_welcome_16_2_shown_key\" value=\"true\" />
    <boolean name=\"pref_update_multi_finger_gestures_shown_key\" value=\"true\" />
</map>"
printf '%s\n' "$PREFS_XML" | adb shell "run-as $TB_PKG sh -c 'mkdir -p $PREFS_DIR && cat > $PREFS_DIR/$PREFS_FILE'" \
  || fail "run-as write of $PREFS_DIR/$PREFS_FILE failed (is the TalkBack build debuggable?)"
WRITTEN="$(adb shell "run-as $TB_PKG cat $PREFS_DIR/$PREFS_FILE" | tr -d '\r')"
printf '%s\n' "$WRITTEN" | grep -q '"pref_log_level">2<' || fail "read-back of $PREFS_FILE does not show pref_log_level 2: $WRITTEN"
say "step 6 done, file reads back as:"
printf '%s\n' "$WRITTEN" | sed 's/^/talkback-probe:   /'

say "step 7: enabling the accessibility service through secure settings, and waiting until it is bound"
say "state before enabling:"
show_a11y_state
BOUND=0
ATTEMPT=1
while [ "$ATTEMPT" -le 3 ]; do
  say "enable attempt $ATTEMPT of 3"
  if [ "$ATTEMPT" -gt 1 ]; then
    # Writing a value the setting already holds notifies nobody, so clear first.
    say "re-reading enabled_accessibility_services before retrying: $(adb shell settings get secure enabled_accessibility_services | tr -d '\r')"
    adb shell settings delete secure enabled_accessibility_services
    sleep 2
  fi
  adb shell settings put secure enabled_accessibility_services "$TB_COMPONENT" || fail "settings put enabled_accessibility_services failed"
  adb shell settings put secure accessibility_enabled 1 || fail "settings put accessibility_enabled failed"
  say "written, state right after the write (this proves nothing about binding):"
  show_a11y_state
  if poll 60 "TalkBack enabled, bound (label=TalkBack) and touch exploration on" tb_bound; then
    BOUND=1
    break
  fi
  say "attempt $ATTEMPT: TalkBack is not bound after 60s, state now:"
  show_a11y_state
  say "  accessibility manager and force-stop lines for TalkBack in logcat so far:"
  adb logcat -d 2>/dev/null | grep -E 'Force stopping com.android.talkback|PACKAGE_RESTARTED|AccessibilityManagerService.*(talkback|Removing|remov)' | tail -n 15 | sed 's/^/talkback-probe:     /'
  ATTEMPT=$((ATTEMPT + 1))
done
[ "$BOUND" -eq 1 ] || fail "TalkBack never appeared under Bound services in dumpsys accessibility after 3 enable attempts; see dumpsys-accessibility.txt and logcat-full.txt in the artifact"
say "TalkBack is bound; state:"
show_a11y_state
poll 90 "TalkBack process" tb_running || fail "TalkBack is bound but has no process"
poll 60 "first log line tagged 'talkback: '" tb_tagged_line || fail "TalkBack is bound but no log line carries a 'talkback: ' tag, so the log level preference was not applied"
say "TTS engines on the device:"
adb shell cmd package query-services --brief -a android.intent.action.TTS_SERVICE | tr -d '\r' | sed 's/^/talkback-probe:   /'
say "default TTS engine setting: $(adb shell settings get secure tts_default_synth | tr -d '\r')"
poll 60 "TalkBack first utterance (start-up announcement)" spoke_any || say "TalkBack has not spoken anything on its own yet; continuing, the gate is on what follows the app launch"
say "focused window before launch:"
adb shell dumpsys window | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | sed 's/^/talkback-probe:   /'

say "step 8: installing and launching $APP_ID"
adb install -r "$APP_APK" || fail "adb install of the app failed"
MARKER="LAUNCH-MARKER-$(date +%s)"
adb shell log -t talkback-probe "$MARKER"
adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 || fail "could not launch $APP_ID"
say "launched $APP_ID, waiting ${WAIT_SECONDS}s"
sleep "$WAIT_SECONDS"
say "focused window after launch:"
adb shell dumpsys window | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | sed 's/^/talkback-probe:   /'

say "step 9: collecting"
collect
LOG="$OUT_DIR/logcat-full.txt"
[ -s "$LOG" ] || fail "logcat dump is empty"
say "logcat lines: $(wc -l < "$LOG"), lines tagged by TalkBack: $(grep -cE '[VDIWEF] talkback: ' "$LOG")"
grep -qF "$MARKER" "$LOG" || fail "launch marker $MARKER is not in the logcat dump (buffer overwritten?)"

# Lines before the marker are TalkBack's own start-up speech, lines after it are
# the response to the app. Only the second set is the gate.
awk -v m="$MARKER" 'index($0, m) { found = 1 } !found' "$LOG" > "$OUT_DIR/logcat-before-launch.txt"
awk -v m="$MARKER" 'index($0, m) { found = 1 } found' "$LOG" > "$OUT_DIR/logcat-after-launch.txt"
grep -F 'SpeechControllerImpl' "$OUT_DIR/logcat-before-launch.txt" | grep -F -- "$SPOKEN_PATTERN" > "$OUT_DIR/talkback-spoken-before-launch.txt"
grep -F 'SpeechControllerImpl' "$OUT_DIR/logcat-after-launch.txt" | grep -F -- "$SPOKEN_PATTERN" > "$OUT_DIR/talkback-spoken.txt"
sed -n 's/.*Speaking fragment text=\(.*\), utteranceId=.*/\1/p' "$OUT_DIR/talkback-spoken.txt" > "$OUT_DIR/talkback-spoken-text.txt"

BEFORE_COUNT="$(wc -l < "$OUT_DIR/talkback-spoken-before-launch.txt")"
AFTER_COUNT="$(wc -l < "$OUT_DIR/talkback-spoken.txt")"
say "spoken lines before launch: $BEFORE_COUNT"
if [ "$BEFORE_COUNT" -gt 0 ]; then
  sed 's/^/talkback-probe:   /' "$OUT_DIR/talkback-spoken-before-launch.txt"
fi
say "spoken lines after launch: $AFTER_COUNT"
if [ "$AFTER_COUNT" -gt 0 ]; then
  sed 's/^/talkback-probe:   /' "$OUT_DIR/talkback-spoken.txt"
  say "spoken text only:"
  sed 's/^/talkback-probe:   /' "$OUT_DIR/talkback-spoken-text.txt"
  say "PASS: TalkBack spoke $AFTER_COUNT line(s) after $APP_ID was launched"
fi

if [ "$AFTER_COUNT" -eq 0 ]; then
  say "diagnostics for a run with no spoken line after launch:"
  for needle in 'TTS is not ready' 'Voice feedback is off' 'SilenceSpeech' 'TTS client crashed'; do
    say "  lines containing '$needle': $(grep -cF -- "$needle" "$LOG")"
  done
  say "  last 25 TalkBack log lines after launch:"
  grep -E '[VDIWEF] talkback: ' "$OUT_DIR/logcat-after-launch.txt" | tail -n 25 | sed 's/^/talkback-probe:     /'
  fail "TalkBack spoke no line after the app was launched (spoken before launch: $BEFORE_COUNT); see logcat-full.txt in the artifact"
fi

# Phase 2 (order 623): the announcement probe. Only when PROBE_APK is set, and
# only after the gate above passed, so a red gate still reads as before.
if [ -z "$PROBE_APK" ]; then
  say "PROBE_APK is not set, the announcement probe is skipped"
  exit 0
fi

say "step 10: announcement probe ($PROBE_APK), installed over $APP_ID"
[ -f "$PROBE_APK" ] || fail "PROBE_APK is not a file: $PROBE_APK"
# Let the exit trap dump the whole logcat again at the end, so a failure in this
# phase still leaves the full log in the artifact.
COLLECTED=0
# Same package id, same debug signing in CI, so -r replaces the app in place. If
# the signatures ever differ, remove the app and install again.
if ! adb install -r "$PROBE_APK"; then
  say "adb install -r of the probe failed, uninstalling $APP_ID and installing again"
  adb uninstall "$APP_ID"
  adb install "$PROBE_APK" || fail "adb install of the announcement probe failed"
fi
probe_done() { adb logcat -d 2>/dev/null | grep -qF 'LUDO_PROBE_DONE'; }
PROBE_MARKER="PROBE-MARKER-$(date +%s)"
adb shell log -t talkback-probe "$PROBE_MARKER"
adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 || fail "could not launch the announcement probe ($APP_ID)"
say "launched the announcement probe, waiting up to ${PROBE_TIMEOUT}s for LUDO_PROBE_DONE"
poll "$PROBE_TIMEOUT" "announcement probe script finished" probe_done || say "the probe did not report LUDO_PROBE_DONE in time, counting what was recorded"
say "recording ${PROBE_TAIL}s more so the last utterance is in the log"
sleep "$PROBE_TAIL"

say "step 11: counting what TalkBack spoke for each case"
PLOG="$OUT_DIR/logcat-probe-full.txt"
timeout 90 adb logcat -d -v threadtime > "$PLOG" 2>&1
[ -s "$PLOG" ] || fail "logcat dump after the announcement probe is empty"
grep -qF "$PROBE_MARKER" "$PLOG" || fail "probe marker $PROBE_MARKER is not in the logcat dump (buffer overwritten?)"
awk -v m="$PROBE_MARKER" 'index($0, m) { found = 1 } found' "$PLOG" > "$OUT_DIR/logcat-probe-announce.txt"
grep -F 'SpeechControllerImpl' "$OUT_DIR/logcat-probe-announce.txt" | grep -F -- "$SPOKEN_PATTERN" > "$OUT_DIR/talkback-announce-spoken.txt"
say "probe window: $(wc -l < "$OUT_DIR/logcat-probe-announce.txt") logcat lines, $(wc -l < "$OUT_DIR/talkback-announce-spoken.txt") spoken lines"
bash "$SCRIPT_DIR/count_cases.sh" "$OUT_DIR/logcat-probe-announce.txt" "$OUT_DIR/talkback-announce-spoken.txt" > "$OUT_DIR/announce-cases.txt"
CASES_RC=$?
sed 's/^/talkback-probe: /' "$OUT_DIR/announce-cases.txt"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo '### TalkBack announcement probe'; echo; echo '```'; cat "$OUT_DIR/announce-cases.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi
[ "$CASES_RC" -eq 0 ] || fail "the announcement probe never ran: no LUDO_PROBE_CASE_START line after the launch (count_cases.sh exit $CASES_RC); see logcat-probe-full.txt in the artifact"
say "PASS: the announcement probe ran; the counts above are the measurement"
exit 0
