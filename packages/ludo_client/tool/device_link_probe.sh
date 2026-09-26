#!/bin/sh
# Delivers a room link to the installed app on the one booted device on adb,
# cold (fresh process, no prior task) and then warm (app already in the
# foreground), and proves the code lands where uiautomator can read it --
# the same accessibility tree Flutter exposes a text field's contents
# through, which is what the join field's dumped text actually is. See
# order 190. Run from packages/ludo_client, with app.fayad.ludo already
# installed; assumes exactly one device on adb.
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
# found or not, for the caller to read back on a miss.
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

# Cold leg.
deliver "$COLD_CODE" yes
poll_for_code "$COLD_CODE" /sdcard/link-cold.xml link-cold.xml
COLD_RESULT="$POLL_RESULT"
adb exec-out screencap -p > link-cold.png

# Warm leg. No force-stop: the app is still in the foreground from the cold
# leg above, so this link has to reach it through singleTop / onNewIntent
# instead of a cold start.
deliver "$WARM_CODE" no
poll_for_code "$WARM_CODE" /sdcard/link-warm.xml link-warm.xml
WARM_RESULT="$POLL_RESULT"
adb exec-out screencap -p > link-warm.png

echo "device-link-probe: cold $COLD_RESULT"
if [ "$COLD_RESULT" = "MISSING" ]; then
  echo "device-link-probe: cold dump (first 4000 characters)"
  head -c 4000 link-cold.xml 2>/dev/null
  echo ""
fi

echo "device-link-probe: warm $WARM_RESULT"
if [ "$WARM_RESULT" = "MISSING" ]; then
  echo "device-link-probe: warm dump (first 4000 characters)"
  head -c 4000 link-warm.xml 2>/dev/null
  echo ""
fi

if [ "$COLD_RESULT" = "FOUND" ] && [ "$WARM_RESULT" = "FOUND" ]; then
  exit 0
fi
exit 1
