#!/bin/sh
# Delivers a room link to the installed app on the one booted device on adb,
# cold (fresh process, no prior task) and then warm (app already in the
# foreground), and proves the code lands where uiautomator can read it --
# the same accessibility tree Flutter exposes a text field's contents
# through, which is what the join field's dumped text actually is. See
# order 190. Run from packages/ludo_client, with app.fayad.ludo already
# installed; assumes exactly one device on adb.
#
# Each leg reports FOUND, MISSING, or INSTRUMENT-BLIND. MISSING means the
# accessibility tree was read but the code was not in it; INSTRUMENT-BLIND
# means the tree itself had nothing to read -- no EditText node carried any
# text at all, not even the name field's, which always does -- so a missing
# code there is not evidence the link failed to land, only that this probe
# could not tell either way. Order 190 RESPEC 1 added this distinction after
# run 36220114933 reported plain MISSING on both legs for a reason that
# turned out to be neither: the wrong apk was installed.
#
# POSIX sh, not bash: no arrays, no `local`, no `[[`, so this also runs
# under dash. Not `set -e`: a poll that finds nothing on its first attempt
# is not a script error, it is the thing being measured, and the two legs
# below both need to run and report even when the other one missed.

PACKAGE="app.fayad.ludo"
COLD_CODE="K7M2QP"
WARM_CODE="H4XR9T"
POLL_TOTAL_SECONDS=45
POLL_INTERVAL_SECONDS=3

# deliver CODE FORCE_STOP
# Sends the room link for CODE to PACKAGE explicitly, by package name, via
# `am start -W`. FORCE_STOP is "yes" for the cold leg (force-stops the app
# first, so the link starts a fresh process) and "no" for the warm leg
# (leaves the app in the foreground from the previous leg, so the link
# arrives through singleTop / onNewIntent instead). Echoes the `am start`
# output in full either way.
deliver() {
  code="$1"
  force_stop="$2"
  if [ "$force_stop" = "yes" ]; then
    adb shell am force-stop "$PACKAGE"
  fi
  am_output=$(adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "https://ludo.provefair.app/r/${code}" "$PACKAGE" 2>&1)
  echo "$am_output"
  if [ "$force_stop" = "yes" ]; then
    echo "device-link-probe: the package name on this am start is explicit because assetlinks.json is 404 by design today and the domain is not verified -- this proves the intent filter matches and the app reads the link, not that verification passed"
  fi
}

# poll_for_code CODE REMOTE_XML LOCAL_XML
# Polls up to POLL_TOTAL_SECONDS, every POLL_INTERVAL_SECONDS: dumps the
# accessibility tree to REMOTE_XML on the device, pulls it to LOCAL_XML,
# and looks for CODE in it. Sets result to FOUND or MISSING in
# POLL_RESULT. LOCAL_XML holds whatever the last pull produced either way,
# found or not, for the caller to read back on a miss. MISSING here is not
# yet the final word: the caller still runs edittext_has_text on LOCAL_XML
# to tell an empty join field apart from a dump that exposed nothing at
# all (INSTRUMENT-BLIND).
poll_for_code() {
  code="$1"
  remote_xml="$2"
  local_xml="$3"
  elapsed=0
  POLL_RESULT="MISSING"
  while true; do
    adb shell uiautomator dump "$remote_xml" >/dev/null 2>&1
    adb pull "$remote_xml" "$local_xml" >/dev/null 2>&1
    if [ -f "$local_xml" ] && grep -q "$code" "$local_xml"; then
      POLL_RESULT="FOUND"
      break
    fi
    if [ "$elapsed" -ge "$POLL_TOTAL_SECONDS" ]; then
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
}

# split_nodes LOCAL_XML
# uiautomator writes the whole hierarchy as one line; this breaks it back
# into one node per line, on stdout, so grep and sed below can address a
# single node's attributes instead of matching anywhere in the file.
split_nodes() {
  local_xml="$1"
  sed 's/<node/\
<node/g' "$local_xml"
}

# edittext_has_text LOCAL_XML
# True (exit 0) only if LOCAL_XML contains at least one
# android.widget.EditText node whose text attribute is non-empty. The name
# field always has text, cold or warm, so this is the control: it is what
# tells an empty join field (the code really is MISSING) apart from a dump
# that exposed nothing usable at all (INSTRUMENT-BLIND), which run
# 36220114933 could not, having only the first 4000 characters to read.
edittext_has_text() {
  local_xml="$1"
  split_nodes "$local_xml" | grep 'class="android.widget.EditText"' | grep -Eq 'text="[^"]+"'
}

# print_edittext_values LOCAL_XML
# Prints one line per android.widget.EditText node in LOCAL_XML, showing
# both its text and hint attributes, so a MISSING or INSTRUMENT-BLIND run
# can be read from the step log alone.
print_edittext_values() {
  local_xml="$1"
  split_nodes "$local_xml" | grep 'class="android.widget.EditText"' | while IFS= read -r node_line; do
    text_value=$(printf '%s' "$node_line" | sed -n 's/.*text="\([^"]*\)".*/\1/p')
    hint_value=$(printf '%s' "$node_line" | sed -n 's/.*hint="\([^"]*\)".*/\1/p')
    echo "device-link-probe: EditText text=\"$text_value\" hint=\"$hint_value\""
  done
}

# component_package COMPONENT
# Echoes the package part of an Android component name: everything before
# the first slash, so "app.fayad.ludo/.MainActivity" gives "app.fayad.ludo".
component_package() {
  printf '%s\n' "${1%%/*}"
}

# implicit_tap_probe
# Measures what a friend's tap on the room link does: an implicit VIEW of the
# link with no package, the intent WhatsApp and Telegram fire. The legs above
# name the package, so they prove the intent filter and the app's link
# handling; they cannot say whether Android would hand a real tap to the app
# or to a browser. That depends on the domain being verified, and
# assetlinks.json is 404 by design today. The day it starts serving, this
# same leg is where the tap moves from OTHER to APP.
#
# A measurement, never a failure: nothing here touches the probe's exit code,
# and an image with no browser is a result (OTHER or UNKNOWN), not an error.
# The component comes from the `Activity:` line of `am start -W` when it
# printed one, else from the resumed activity in dumpsys, whichever of
# mResumedActivity or topResumedActivity this API level prints. Variables
# are tap_-prefixed so none of them can touch the cold and warm results.
implicit_tap_probe() {
  tap_url="https://ludo.provefair.app/r/T4PW9C"
  tap_component=""
  tap_reason=""

  echo "device-link-probe: pm get-app-links $PACKAGE"
  adb shell pm get-app-links "$PACKAGE" 2>&1

  adb shell am force-stop "$PACKAGE"
  tap_output=$(adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$tap_url" 2>&1 | tr -d '\r')
  echo "$tap_output"

  tap_line=$(printf '%s\n' "$tap_output" | grep -E '^[[:space:]]*Activity:' | head -n 1)
  if [ -n "$tap_line" ]; then
    echo "device-link-probe: component read from am start: $tap_line"
    tap_component=$(printf '%s\n' "$tap_line" | sed 's/^[[:space:]]*Activity:[[:space:]]*//; s/[[:space:]]*$//')
  elif printf '%s\n' "$tap_output" | grep -q 'Error:'; then
    tap_reason="am start reported an error and started nothing"
  else
    tap_line=$(adb shell dumpsys activity activities 2>&1 | tr -d '\r' | grep -E 'mResumedActivity|topResumedActivity' | head -n 1)
    if [ -n "$tap_line" ]; then
      echo "device-link-probe: component read from dumpsys: $tap_line"
      tap_component=$(printf '%s\n' "$tap_line" | sed -n 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/p')
    fi
  fi

  if [ -z "$tap_component" ]; then
    if [ -z "$tap_reason" ]; then
      tap_reason="no Activity line in am start output and no resumed activity in dumpsys"
    fi
    echo "device-link-probe: implicit tap -> UNKNOWN ($tap_reason)"
  else
    tap_package=$(component_package "$tap_component")
    if [ "$tap_package" = "$PACKAGE" ]; then
      echo "device-link-probe: implicit tap -> APP ($tap_component)"
    else
      echo "device-link-probe: implicit tap -> OTHER ($tap_component)"
      # The resolver runs inside the "android" package, which must not be
      # force-stopped; HOME below dismisses it. Anything else is a browser
      # (or similar) the tap opened, so stop it.
      if [ "$tap_package" != "android" ]; then
        adb shell am force-stop "$tap_package"
      fi
    fi
  fi

  adb shell input keyevent KEYCODE_HOME
}

# Cold leg.
deliver "$COLD_CODE" yes
poll_for_code "$COLD_CODE" /sdcard/link-cold.xml link-cold.xml
COLD_RESULT="$POLL_RESULT"
if [ "$COLD_RESULT" = "MISSING" ] && ! edittext_has_text link-cold.xml; then
  COLD_RESULT="INSTRUMENT-BLIND"
fi
adb exec-out screencap -p > link-cold.png

# Warm leg. No force-stop: the app is still in the foreground from the cold
# leg above, so this link has to reach it through singleTop / onNewIntent
# instead of a cold start.
deliver "$WARM_CODE" no
poll_for_code "$WARM_CODE" /sdcard/link-warm.xml link-warm.xml
WARM_RESULT="$POLL_RESULT"
if [ "$WARM_RESULT" = "MISSING" ] && ! edittext_has_text link-warm.xml; then
  WARM_RESULT="INSTRUMENT-BLIND"
fi
adb exec-out screencap -p > link-warm.png

echo "device-link-probe: cold $COLD_RESULT"
if [ "$COLD_RESULT" != "FOUND" ]; then
  print_edittext_values link-cold.xml
fi

echo "device-link-probe: warm $WARM_RESULT"
if [ "$WARM_RESULT" != "FOUND" ]; then
  print_edittext_values link-warm.xml
fi

# Implicit-tap leg. After both legs have reported, so their lines and the
# files they leave behind are exactly as before; it does not feed the exit
# code below.
implicit_tap_probe

if [ "$COLD_RESULT" = "FOUND" ] && [ "$WARM_RESULT" = "FOUND" ]; then
  exit 0
fi
exit 1
