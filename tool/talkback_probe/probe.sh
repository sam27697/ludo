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
# Exit codes: 0 TalkBack spoke at least once after the app was launched;
# 1 it did not (or an earlier step failed; the message says which).

OUT_DIR="${OUT_DIR:-probe-out}"
APP_ID="${APP_ID:-app.fayad.ludo}"
WAIT_SECONDS="${WAIT_SECONDS:-45}"
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

logcat_has() { adb logcat -d 2>/dev/null | grep -qF -- "$1"; }
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
adb install -r -t "$TALKBACK_APK" || fail "adb install of TalkBack failed (INSTALL_FAILED_NO_MATCHING_ABIS means the APK has no x86_64 libraries)"
adb shell pm path "$TB_PKG" | grep -q '^package:' || fail "$TB_PKG is not installed after adb install"
if adb shell cmd package query-services --brief -a android.accessibilityservice.AccessibilityService | tr -d '\r' | grep -qF "$TB_COMPONENT"; then
  say "step 4 done: $TB_COMPONENT is installed and registered as an accessibility service"
else
  say "step 4 done: $TB_PKG is installed, but query-services did not list $TB_COMPONENT; the enable step below decides"
fi

say "step 5: granting the runtime permissions TalkBack would otherwise ask for with a dialog"
for perm in android.permission.POST_NOTIFICATIONS android.permission.READ_PHONE_STATE android.permission.RECORD_AUDIO; do
  if adb shell pm grant "$TB_PKG" "$perm"; then say "granted $perm"; else say "could not grant $perm (not fatal; a dialog may appear)"; fi
done

say "step 6: writing TalkBack's preferences (log level VERBOSE, first-run screens off) with run-as"
adb shell am force-stop "$TB_PKG"
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

say "step 7: enabling the accessibility service through secure settings"
say "enabled_accessibility_services before: $(adb shell settings get secure enabled_accessibility_services | tr -d '\r')"
adb shell settings put secure enabled_accessibility_services "$TB_COMPONENT" || fail "settings put enabled_accessibility_services failed"
adb shell settings put secure accessibility_enabled 1 || fail "settings put accessibility_enabled failed"
say "enabled_accessibility_services now: $(adb shell settings get secure enabled_accessibility_services | tr -d '\r')"
say "accessibility_enabled now: $(adb shell settings get secure accessibility_enabled | tr -d '\r')"
poll 90 "TalkBack process" tb_running || fail "TalkBack did not start after it was enabled"
poll 60 "TalkBack verbose log lines" logcat_has 'talkback: ' || fail "no 'talkback: ' log lines after start, so the log level preference was not applied"
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
say "logcat lines: $(wc -l < "$LOG"), lines tagged by TalkBack: $(grep -c 'talkback: ' "$LOG")"
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
  exit 0
fi

say "diagnostics for a run with no spoken line after launch:"
for needle in 'TTS is not ready' 'Voice feedback is off' 'SilenceSpeech' 'TTS client crashed'; do
  say "  lines containing '$needle': $(grep -cF -- "$needle" "$LOG")"
done
say "  last 25 TalkBack log lines after launch:"
grep -F 'talkback: ' "$OUT_DIR/logcat-after-launch.txt" | tail -n 25 | sed 's/^/talkback-probe:     /'
fail "TalkBack spoke no line after the app was launched (spoken before launch: $BEFORE_COUNT); see logcat-full.txt in the artifact"
