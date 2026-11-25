#!/bin/sh
# Delivers a room link to the installed app on the one booted device on adb,
# cold (fresh process, no saved name) and then warm (app already in the
# foreground, a name in the field), and reads what home and the room route
# show through uiautomator, the accessibility tree Flutter exposes its
# semantics through. See orders 190 and 718. Run from packages/ludo_client,
# with app.fayad.ludo already installed; assumes exactly one device on adb.
#
# What the app does with a link since order 701 (lib/src/home_screen.dart,
# _handleLink and _decideLinkAction): /r/<x> is read as a link id, shape
# [0-9a-z]{4,10}-[0-9a-z]{6} (roomLinkIdFromUri in lib/src/deep_link.dart).
# A six-letter room code in /r/ is not a link id and only raises the
# invalid-code home notice, so the probe sends link ids, never codes. With no
# name in the field the link waits: home shows the name-required line
# (Key home-name-required, homeNameRequired in lib/l10n/app_en.arb) and the
# name field takes focus. A name submitted from the keyboard sends
# join_room with the link, and RoomRoute is pushed with fromLink true.
#
# The answered state. The link ids below are made up, so the server (the
# probe apk is a plain `flutter build apk --profile`, no dart-define, so it
# talks to kDefaultServerUrl, wss://ludo.provefair.app, production) answers
# NO_SUCH_ROOM: docs/PROTOCOL.md says an unknown link is NO_SUCH_ROOM. A
# fromLink join that gets NO_SUCH_ROOM stays on the lobby's error card with
# lobbyErrorLinkRoomGone (lib/src/lobby_screen.dart, _errorBody). The
# answered state is exactly one of two cards, and the verdict line says
# which: that one, "room gone", or the update-required card, "update
# required", whose title is updateRequiredTitle (UpdateRequiredView, shown
# by LobbyScreen when controller.updateRequired is set by the server's
# UPDATE_REQUIRED). The second counts because the probe apk carries the
# pubspec's build number, which is below production's minimum client build,
# so production answers every join from it with the update gate (run
# 45525832503 showed it): the gate is the server's answer to the join the
# link caused. The route does not pop on its own (only Back to home pops
# it), so no home notice is expected. Two other cards the same route can
# show are printed, never counted: lobbyErrorTransport (the server was not reached, so nothing was
# answered) and lobbyErrorRateLimited (answered, but not for this link).
#
# Each leg reports FOUND, MISSING, or INSTRUMENT-BLIND. The control against
# blindness is the Create Room button's label (homeCreateRoomButton), on home
# in every state since order 701; the hint of the name field is not used,
# since an empty field exposes no text. MISSING means the control was in the
# tree and the leg's text was not; INSTRUMENT-BLIND means the dump did not
# hold the control, so this probe could not tell either way. The cold leg is
# FOUND only when both its halves are: the name-required line after the link,
# then the answered state after the name is typed. Order 190 RESPEC 1 added
# the blind verdict after run 36220114933 reported plain MISSING on both legs
# for a reason that turned out to be neither: the wrong apk was installed.
#
# Every text looked for is read from lib/l10n/app_en.arb at run time, by key,
# so a copy change there does not leave a stale string here. The device runs
# in English. None of the strings used holds a character uiautomator escapes.
#
# POSIX sh, not bash: no arrays, no `local`, no `[[`, so this also runs
# under dash. Not `set -e`: a poll that finds nothing on its first attempt
# is not a script error, it is the thing being measured, and the two legs
# below both need to run and report even when the other one missed.

PACKAGE="app.fayad.ludo"
ARB="lib/l10n/app_en.arb"
COLD_LINK_ID="probec-k7m2qp"
WARM_LINK_ID="probew-h4xr9t"
PROBE_NAME="Probe"
POLL_TOTAL_SECONDS=45
POLL_INTERVAL_SECONDS=3

# arb_string KEY
# Echoes the English string for KEY from ARB, or nothing when the key is not
# there. The arb file holds one "key": "value", pair per line.
arb_string() {
  sed -n "s/^  \"$1\": \"\\(.*\\)\",\\{0,1\\}\$/\\1/p" "$ARB" | head -n 1
}

CONTROL_TEXT=$(arb_string homeCreateRoomButton)
NAME_REQUIRED_TEXT=$(arb_string homeNameRequired)
ANSWERED_TEXT=$(arb_string lobbyErrorLinkRoomGone)
UPDATE_TEXT=$(arb_string updateRequiredTitle)
TRANSPORT_TEXT=$(arb_string lobbyErrorTransport)
RATE_LIMITED_TEXT=$(arb_string lobbyErrorRateLimited)
BACK_HOME_TEXT=$(arb_string lobbyBackToHomeButton)
CONNECTING_TEXT=$(arb_string lobbyConnecting)
for arb_value in "$CONTROL_TEXT" "$NAME_REQUIRED_TEXT" "$ANSWERED_TEXT" "$UPDATE_TEXT" "$TRANSPORT_TEXT" "$RATE_LIMITED_TEXT" "$BACK_HOME_TEXT" "$CONNECTING_TEXT"; do
  if [ -z "$arb_value" ]; then
    echo "device-link-probe: a key this probe needs is missing from $ARB; run from packages/ludo_client" >&2
    exit 2
  fi
done
echo "device-link-probe: control \"$CONTROL_TEXT\", name-required \"$NAME_REQUIRED_TEXT\", answered \"$ANSWERED_TEXT\" or \"$UPDATE_TEXT\""

# Page-button leg (order 461). LINK_PAGE_HOST is the one input taken from the
# environment: the staging host serves the same page, with the same
# intent:// link to ludo.provefair.app, so a run can measure either. The id
# is a link id since order 718: run 08a1dda showed the page answers a
# six-letter code with "This invite link looks cut off" and no button.
LINK_PAGE_HOST="${LINK_PAGE_HOST:-ludo.provefair.app}"
BUTTON_CODE="probeb-b8nv3k"
BUTTON_LABEL="Open in Ludo RNG"
BUTTON_PAGE_SECONDS=45
BUTTON_APP_SECONDS=30
POLL_DECLINE_MAX=4
CHROME_PACKAGE="com.android.chrome"

# deliver LINK_ID FORCE_STOP
# Sends the room link for LINK_ID to PACKAGE explicitly, by package name, via
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

# dump_screen REMOTE_XML LOCAL_XML
# One uiautomator dump, pulled to LOCAL_XML. LOCAL_XML is removed first so a
# dump that failed cannot leave an old one to be read as this one.
dump_screen() {
  rm -f "$2"
  adb shell uiautomator dump "$1" >/dev/null 2>&1
  adb pull "$1" "$2" >/dev/null 2>&1
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

# has_text LOCAL_XML TEXT
# True (exit 0) only if LOCAL_XML exists and some node's text or
# content-desc attribute holds TEXT. A substring match, because Flutter
# merges a button's label and a field's label and hint into one attribute
# (run 08a1dda dumped the name field's hint as "Your name&#10;Your name").
# The hint attribute is never read.
has_text() {
  if [ ! -f "$1" ]; then
    return 1
  fi
  {
    split_nodes "$1" | sed -n 's/.* text="\([^"]*\)".*/\1/p'
    split_nodes "$1" | sed -n 's/.* content-desc="\([^"]*\)".*/\1/p'
  } | grep -qF -e "$2"
}

# poll_for_text TEXT REMOTE_XML LOCAL_XML
# Polls up to POLL_TOTAL_SECONDS, every POLL_INTERVAL_SECONDS, for TEXT in
# the dump. Sets POLL_RESULT to FOUND or MISSING. LOCAL_XML holds the last
# dump either way, for the caller to tell MISSING from INSTRUMENT-BLIND.
poll_for_text() {
  want="$1"
  remote_xml="$2"
  local_xml="$3"
  elapsed=0
  POLL_RESULT="MISSING"
  while true; do
    dump_screen "$remote_xml" "$local_xml"
    if has_text "$local_xml" "$want"; then
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

# home_verdict LOCAL_XML
# After a poll on home: FOUND stays FOUND; otherwise MISSING when the
# control (the Create Room label) is in the dump, INSTRUMENT-BLIND when not.
home_verdict() {
  if [ "$POLL_RESULT" = "FOUND" ]; then
    echo "FOUND"
  elif has_text "$1" "$CONTROL_TEXT"; then
    echo "MISSING"
  else
    echo "INSTRUMENT-BLIND"
  fi
}

# poll_for_answer REMOTE_XML LOCAL_XML
# poll_for_text for the answered state, which is either of two cards. Sets
# POLL_RESULT to FOUND or MISSING and ANSWER_KIND to "room gone" or "update
# required" on FOUND, nothing on a miss.
poll_for_answer() {
  remote_xml="$1"
  local_xml="$2"
  elapsed=0
  POLL_RESULT="MISSING"
  ANSWER_KIND=""
  while true; do
    dump_screen "$remote_xml" "$local_xml"
    if has_text "$local_xml" "$ANSWERED_TEXT"; then
      ANSWER_KIND="room gone"
    elif has_text "$local_xml" "$UPDATE_TEXT"; then
      ANSWER_KIND="update required"
    fi
    if [ -n "$ANSWER_KIND" ]; then
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

# answered_verdict LOCAL_XML
# After poll_for_answer: "FOUND (room gone)" or "FOUND (update required)". The control here is wider than home's,
# because the answered state is on the room route, where Create Room is not:
# the dump is readable when it holds Create Room (still on home), the
# lobby's connecting line, its Back to home button, or one of the two cards
# that are not this answer (transport, rate limited). Which of those it was
# is printed.
answered_verdict() {
  if [ "$POLL_RESULT" = "FOUND" ]; then
    echo "FOUND ($ANSWER_KIND)"
    return
  fi
  for seen_text in "$TRANSPORT_TEXT" "$RATE_LIMITED_TEXT" "$CONNECTING_TEXT" "$BACK_HOME_TEXT" "$CONTROL_TEXT"; do
    if has_text "$1" "$seen_text"; then
      echo "device-link-probe: no answer in $1, it shows \"$seen_text\"" >&2
      echo "MISSING"
      return
    fi
  done
  echo "INSTRUMENT-BLIND"
}

# print_edittext_values LOCAL_XML
# Prints one line per android.widget.EditText node in LOCAL_XML, showing
# both its text and hint attributes, so a MISSING or INSTRUMENT-BLIND run
# can be read from the step log alone.
print_edittext_values() {
  local_xml="$1"
  if [ ! -f "$local_xml" ]; then
    return
  fi
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
# The poll_for_text loop, looking for a node by its exact label,
# with its own timeout. Sets NODE_CENTRE to "X Y", or to nothing on a miss.
# LOCAL_XML is removed first so a dump that failed cannot leave an old one
# to be read as this one.
#
# When a dump has no such node but does hold a node that declines something
# ("No thanks", "Use without an account", "Got it": Chrome's own promo
# dialogs sit over the page and hide it), that node is tapped, what was
# tapped is printed, and the poll goes on inside the same TOTAL_SECONDS. At
# most POLL_DECLINE_MAX such taps. Nothing that accepts is ever tapped:
# "Continue" and "Accept & continue" are not in the list.
poll_for_node() {
  label="$1"
  remote_xml="$2"
  local_xml="$3"
  total="$4"
  elapsed=0
  declines=0
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
    if [ -f "$local_xml" ] && [ "$declines" -lt "$POLL_DECLINE_MAX" ]; then
      for decline_label in "No thanks" "Use without an account" "Got it"; do
        decline_xy=$(node_centre "$local_xml" "$decline_label")
        if [ -n "$decline_xy" ]; then
          declines=$((declines + 1))
          echo "device-link-probe: no \"$label\" in the dump, tapping \"$decline_label\" at $decline_xy (decline tap $declines of $POLL_DECLINE_MAX)"
          adb shell input tap $decline_xy
          break
        fi
      done
    fi
    if [ "$elapsed" -ge "$total" ]; then
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
}

# print_node_texts LOCAL_XML
# Prints one line per node in LOCAL_XML that has a non-empty text or
# content-desc, with both in full, so what was on the screen can be read from
# the step log alone.
print_node_texts() {
  echo "device-link-probe: text of every node in $1"
  if [ ! -f "$1" ]; then
    echo "device-link-probe: $1 was never pulled"
    return
  fi
  split_nodes "$1" | grep -E ' (text|content-desc)="[^"]+"' | while IFS= read -r node_line; do
    text_value=$(printf '%s' "$node_line" | sed -n 's/.* text="\([^"]*\)".*/\1/p')
    desc_value=$(printf '%s' "$node_line" | sed -n 's/.* content-desc="\([^"]*\)".*/\1/p')
    echo "device-link-probe: node text=\"$text_value\" content-desc=\"$desc_value\""
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
# front and shows that it read the link id (see the APP branch below). The implicit-tap leg measures
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
# Chrome's notification promo is pre-empted with pm grant and, if it still
# shows, declined inside the button poll. One verdict line: APP FOUND, APP MISSING (app in front, neither
# the name-required line nor the answered state), NOT-APP (<component>), or NO-BUTTON (<reason>), with the dumps
# printed on anything but FOUND.
page_button_probe() {
  btn_url="https://${LINK_PAGE_HOST}/r/${BUTTON_CODE}?lang=en"

  adb shell am set-debug-app --persistent "$CHROME_PACKAGE" 2>&1
  adb shell "echo 'chrome --disable-fre --no-default-browser-check --no-first-run' > /data/local/tmp/chrome-command-line" 2>&1
  # Chrome asks to send notifications in a dialog that covers the page;
  # granting the permission up front keeps it from being asked. A failure is
  # printed and the leg goes on: the decline tap in poll_for_node is the
  # second line of defence.
  grant_output=$(adb shell pm grant "$CHROME_PACKAGE" android.permission.POST_NOTIFICATIONS 2>&1 | tr -d '\r')
  echo "device-link-probe: pm grant POST_NOTIFICATIONS to $CHROME_PACKAGE: ${grant_output:-no output}"
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
    print_node_texts link-page.xml
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
      # The app is confirmed in front first, so nothing on the page can be
      # read as the app's answer. Since order 701 a link with no saved name
      # shows the name-required line, and with a name it goes to the room
      # route; the legs above never save a name (an unknown link id never
      # connects, and only a connected join records one), so after the
      # force-stop above this is expected to be the name-required line.
      # Either text counts: both are only on screen after the app read the
      # link id.
      btn_seen=""
      btn_elapsed=0
      while true; do
        dump_screen /sdcard/link-button.xml link-button.xml
        for btn_text in "$NAME_REQUIRED_TEXT" "$ANSWERED_TEXT"; do
          if has_text link-button.xml "$btn_text"; then
            btn_seen="$btn_text"
            break
          fi
        done
        if [ -n "$btn_seen" ] || [ "$btn_elapsed" -ge "$POLL_TOTAL_SECONDS" ]; then
          break
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        btn_elapsed=$((btn_elapsed + POLL_INTERVAL_SECONDS))
      done
      adb exec-out screencap -p > link-button.png
      if [ -n "$btn_seen" ]; then
        echo "device-link-probe: page button -> APP FOUND (\"$btn_seen\")"
      else
        echo "device-link-probe: page button -> APP MISSING"
        print_node_texts link-button.xml
        print_dump link-page.xml
        print_dump link-button.xml
      fi
    fi
  fi

  adb shell am force-stop "$CHROME_PACKAGE"
  adb shell input keyevent KEYCODE_HOME
}

# Cold leg. pm clear first: the leg is "no saved name", and a name stored
# by anything before this probe (an earlier run, the launch test) would turn
# it into the warm case. The link waits for a name; FOUND for the first half
# is the name-required line on home.
adb shell pm clear "$PACKAGE"
deliver "$COLD_LINK_ID" yes
poll_for_text "$NAME_REQUIRED_TEXT" /sdcard/link-cold.xml link-cold.xml
COLD_LINE_RESULT=$(home_verdict link-cold.xml)
adb exec-out screencap -p > link-cold.png

# Second half of the cold leg: the name goes into the focused field and is
# submitted from the keyboard, which is what sends the waiting link's
# join_room. Only when the line was there; otherwise there is no waiting
# link to send and the half is not run.
COLD_JOIN_RESULT="NOT-RUN"
if [ "$COLD_LINE_RESULT" = "FOUND" ]; then
  adb shell input text "$PROBE_NAME"
  adb shell input keyevent KEYCODE_ENTER
  poll_for_answer /sdcard/link-cold-join.xml link-cold-join.xml
  COLD_JOIN_RESULT=$(answered_verdict link-cold-join.xml)
  adb exec-out screencap -p > link-cold-join.png
fi
if [ "$COLD_LINE_RESULT" = "FOUND" ] && [ "${COLD_JOIN_RESULT%% *}" = "FOUND" ]; then
  COLD_RESULT="FOUND"
elif [ "$COLD_LINE_RESULT" = "INSTRUMENT-BLIND" ] || [ "$COLD_JOIN_RESULT" = "INSTRUMENT-BLIND" ]; then
  COLD_RESULT="INSTRUMENT-BLIND"
else
  COLD_RESULT="MISSING"
fi

# Back to home for the warm leg. A link that arrives while the room route is
# above home does nothing (rule B5 in _decideLinkAction), so the error card
# is left by its Back to home button, or by the back key when the button is
# not in the dump. The process and the typed name stay.
back_xy=""
if [ -f link-cold-join.xml ]; then
  back_xy=$(node_centre link-cold-join.xml "$BACK_HOME_TEXT")
fi
if [ -n "$back_xy" ]; then
  echo "device-link-probe: tapping \"$BACK_HOME_TEXT\" at $back_xy"
  adb shell input tap $back_xy
else
  echo "device-link-probe: no \"$BACK_HOME_TEXT\" node, pressing back"
  adb shell input keyevent KEYCODE_BACK
fi
poll_for_text "$CONTROL_TEXT" /sdcard/link-home.xml link-home.xml
echo "device-link-probe: home before the warm leg: control $POLL_RESULT"

# Warm leg. No force-stop: the app is still in the foreground, so this link
# has to reach it through singleTop / onNewIntent instead of a cold start.
# The name typed above is still in the field, so the join goes out with no
# further input; FOUND is the same answered state as the cold leg's.
deliver "$WARM_LINK_ID" no
poll_for_answer /sdcard/link-warm.xml link-warm.xml
WARM_RESULT=$(answered_verdict link-warm.xml)
adb exec-out screencap -p > link-warm.png

echo "device-link-probe: cold name-required $COLD_LINE_RESULT"
echo "device-link-probe: cold answered $COLD_JOIN_RESULT"
echo "device-link-probe: cold $COLD_RESULT"
if [ "$COLD_LINE_RESULT" != "FOUND" ]; then
  print_node_texts link-cold.xml
  print_edittext_values link-cold.xml
elif [ "${COLD_JOIN_RESULT%% *}" != "FOUND" ]; then
  print_node_texts link-cold-join.xml
fi

echo "device-link-probe: warm $WARM_RESULT"
if [ "${WARM_RESULT%% *}" != "FOUND" ]; then
  print_node_texts link-home.xml
  print_node_texts link-warm.xml
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

if [ "$COLD_RESULT" = "FOUND" ] && [ "${WARM_RESULT%% *}" = "FOUND" ]; then
  exit 0
fi
exit 1
