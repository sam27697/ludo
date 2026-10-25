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

# Page-button leg (order 461). LINK_PAGE_HOST is the one input taken from the
# environment: the staging host serves the same page, with the same
# intent:// link to ludo.provefair.app, so a run can measure either.
LINK_PAGE_HOST="${LINK_PAGE_HOST:-ludo.provefair.app}"
BUTTON_CODE="B8NV3K"
BUTTON_LABEL="Open in Ludo RNG"
BUTTON_PAGE_SECONDS=45
BUTTON_APP_SECONDS=30
CHROME_PACKAGE="com.android.chrome"

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

# resumed_component
# Echoes the component of the resumed activity from dumpsys, whichever of
# mResumedActivity or topResumedActivity this API level prints, or nothing
# when neither line is there.
resumed_component() {
  adb shell dumpsys activity activities 2>&1 | tr -d '\r' | grep -E 'mResumedActivity|topResumedActivity' | head -n 1 | sed -n 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/p'
}

# node_centre LOCAL_XML LABEL
# Echoes "X Y", the centre of the first node in LOCAL_XML whose text or
# content-desc is exactly LABEL and whose bounds have an area, or nothing.
# LABEL is matched as it sits in the XML, so an ampersand is written &amp;.
node_centre() {
  local_xml="$1"
  label="$2"
  split_nodes "$local_xml" | grep -F -e " text=\"$label\"" -e " content-desc=\"$label\"" | while IFS= read -r node_line; do
    node_bounds=$(printf '%s' "$node_line" | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
    if [ -z "$node_bounds" ]; then
      continue
    fi
    set -- $node_bounds
    if [ "$3" -gt "$1" ] && [ "$4" -gt "$2" ]; then
      echo "$((($1 + $3) / 2)) $((($2 + $4) / 2))"
      break
    fi
  done
}

# poll_for_node LABEL REMOTE_XML LOCAL_XML TOTAL_SECONDS
# The poll_for_code loop, looking for a node by its label instead of a code,
# with its own timeout. Sets NODE_CENTRE to "X Y", or to nothing on a miss.
# LOCAL_XML is removed first so a dump that failed cannot leave an old one
# to be read as this one.
poll_for_node() {
  label="$1"
  remote_xml="$2"
  local_xml="$3"
  total="$4"
  elapsed=0
  NODE_CENTRE=""
  rm -f "$local_xml"
  while true; do
    adb shell uiautomator dump "$remote_xml" >/dev/null 2>&1
    adb pull "$remote_xml" "$local_xml" >/dev/null 2>&1
    if [ -f "$local_xml" ]; then
      NODE_CENTRE=$(node_centre "$local_xml" "$label")
    fi
    if [ -n "$NODE_CENTRE" ]; then
      break
    fi
    if [ "$elapsed" -ge "$total" ]; then
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
}

# print_dump LOCAL_XML
# Prints LOCAL_XML one node per line, for a verdict that is not FOUND.
print_dump() {
  echo "device-link-probe: dump $1"
  if [ -f "$1" ]; then
    split_nodes "$1"
    echo
  else
    echo "device-link-probe: $1 was never pulled"
  fi
}

# chrome_first_run_tap
# Second way past Chrome's first-run screen, tried once and only when the
# command-line flags did not skip it: tap the labels of its buttons that
# decline an account (accept the terms, no sign-in, no sync). Nothing is
# typed and no account is touched. Prints the component and every label it
# tapped, so the result is readable from the log.
chrome_first_run_tap() {
  echo "device-link-probe: Chrome still shows its first-run screen after the command-line flags; tapping through it without an account"
  fre_round=0
  while [ "$fre_round" -lt 4 ]; do
    fre_round=$((fre_round + 1))
    adb shell uiautomator dump /sdcard/link-chrome-fre.xml >/dev/null 2>&1
    rm -f link-chrome-fre.xml
    adb pull /sdcard/link-chrome-fre.xml link-chrome-fre.xml >/dev/null 2>&1
    fre_tapped=""
    for fre_label in "Accept &amp; continue" "Use without an account" "No thanks" "Got it"; do
      fre_xy=""
      if [ -f link-chrome-fre.xml ]; then
        fre_xy=$(node_centre link-chrome-fre.xml "$fre_label")
      fi
      if [ -n "$fre_xy" ]; then
        echo "device-link-probe: Chrome first run: tapping \"$fre_label\" at $fre_xy"
        adb shell input tap $fre_xy
        fre_tapped="yes"
        break
      fi
    done
    if [ -z "$fre_tapped" ]; then
      break
    fi
    sleep 2
  done
  echo "device-link-probe: Chrome first run: resumed component after the taps: $(resumed_component)"
}

# page_button_probe
# Walks the friend's whole path on the device: Chrome shows the room link
# page, the "Open in Ludo RNG" button is tapped, and the app comes to the
# front with the code in the join field. The implicit-tap leg measures
# whether Android hands a tapped link to the app; this one measures the way
# in that does not depend on the domain being verified, the intent:// link
# on the page (order 457). The page is opened in Chrome by package, so what
# is measured is the page and the button, not the resolver.
#
# Chrome is taken past its first-run screen with the debug-app command-line
# file, which Chrome reads only on a debuggable image (the emulator's
# google_apis is one); no account is touched. A measurement, never a
# failure: nothing here touches the probe's exit code. Variables are
# btn_-prefixed so none of them can touch the cold and warm results.
# One verdict line: APP FOUND, APP MISSING (app in front, code not in an
# EditText), NOT-APP (<component>), or NO-BUTTON (<reason>), with the dumps
# printed on anything but FOUND.
page_button_probe() {
  btn_url="https://${LINK_PAGE_HOST}/r/${BUTTON_CODE}?lang=en"

  adb shell am set-debug-app --persistent "$CHROME_PACKAGE" 2>&1
  adb shell "echo 'chrome --disable-fre --no-default-browser-check --no-first-run' > /data/local/tmp/chrome-command-line" 2>&1
  adb shell am force-stop "$CHROME_PACKAGE"

  adb shell am force-stop "$PACKAGE"
  echo "device-link-probe: opening $btn_url in $CHROME_PACKAGE"
  btn_output=$(adb shell am start -W -a android.intent.action.VIEW -d "$btn_url" "$CHROME_PACKAGE" 2>&1 | tr -d '\r')
  echo "$btn_output"

  btn_component=$(resumed_component)
  if printf '%s\n%s\n' "$btn_output" "$btn_component" | grep -q 'FirstRunActivity'; then
    chrome_first_run_tap
    btn_output=$(adb shell am start -W -a android.intent.action.VIEW -d "$btn_url" "$CHROME_PACKAGE" 2>&1 | tr -d '\r')
    echo "$btn_output"
  fi

  poll_for_node "$BUTTON_LABEL" /sdcard/link-page.xml link-page.xml "$BUTTON_PAGE_SECONDS"
  adb exec-out screencap -p > link-page.png
  if [ -z "$NODE_CENTRE" ]; then
    btn_component=$(resumed_component)
    if [ ! -f link-page.xml ]; then
      btn_reason="uiautomator produced no dump"
    else
      btn_reason="no node with text or content-desc \"$BUTTON_LABEL\" in ${BUTTON_PAGE_SECONDS}s, resumed activity ${btn_component:-unreadable}"
    fi
    echo "device-link-probe: page button -> NO-BUTTON ($btn_reason)"
    print_dump link-page.xml
  else
    echo "device-link-probe: tapping \"$BUTTON_LABEL\" at $NODE_CENTRE"
    adb shell input tap $NODE_CENTRE

    btn_elapsed=0
    btn_component=""
    while true; do
      btn_component=$(resumed_component)
      if [ "$(component_package "$btn_component")" = "$PACKAGE" ]; then
        break
      fi
      if [ "$btn_elapsed" -ge "$BUTTON_APP_SECONDS" ]; then
        break
      fi
      sleep "$POLL_INTERVAL_SECONDS"
      btn_elapsed=$((btn_elapsed + POLL_INTERVAL_SECONDS))
    done

    if [ "$(component_package "$btn_component")" != "$PACKAGE" ]; then
      adb shell uiautomator dump /sdcard/link-button.xml >/dev/null 2>&1
      rm -f link-button.xml
      adb pull /sdcard/link-button.xml link-button.xml >/dev/null 2>&1
      adb exec-out screencap -p > link-button.png
      echo "device-link-probe: page button -> NOT-APP (${btn_component:-no resumed activity readable})"
      print_dump link-page.xml
      print_dump link-button.xml
    else
      # The page itself shows the code, so a bare grep for it would pass
      # while Chrome is still in front; the app is confirmed first and the
      # code must then sit in an EditText, the join field.
      rm -f link-button.xml
      poll_for_code "$BUTTON_CODE" /sdcard/link-button.xml link-button.xml
      adb exec-out screencap -p > link-button.png
      if [ "$POLL_RESULT" = "FOUND" ] && split_nodes link-button.xml | grep 'class="android.widget.EditText"' | grep -q "$BUTTON_CODE"; then
        echo "device-link-probe: page button -> APP FOUND"
      else
        echo "device-link-probe: page button -> APP MISSING"
        print_edittext_values link-button.xml
        print_dump link-page.xml
        print_dump link-button.xml
      fi
    fi
  fi

  adb shell am force-stop "$CHROME_PACKAGE"
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

# Page-button leg. After the implicit-tap leg, never instead of any leg, and
# like it not part of the exit code below. Its files are link-page.png,
# link-button.png and the matching .xml dumps, which the workflow's
# link-*.png and link-*.xml artifact patterns already pick up.
page_button_probe

if [ "$COLD_RESULT" = "FOUND" ] && [ "$WARM_RESULT" = "FOUND" ]; then
  exit 0
fi
exit 1
