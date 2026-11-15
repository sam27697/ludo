#!/usr/bin/env bash
# Background sampler for the screenshots job: records what the runner host and
# the emulator guest look like over time, so that an emulator that goes offline
# mid-run (C-641: 6 of 8 stills runs, no crash line in the job log) leaves
# evidence of why.
#
# Usage: emulator_watch.sh <outdir>
#
# Writes into <outdir>, every record headed by a UTC timestamp to the
# millisecond:
#   host.log     every 5 s: free -m, load average, qemu/emulator processes
#   guest.log    every 10 s: adb get-state, guest meminfo, app pid, app summary
#   logcat.txt   continuous logcat, restarted (with a marker line) if adb drops
#
# Started in the background by the workflow before the emulator step and
# stopped by its PID file after it. This script must never fail the job, so
# there is no `set -e` and every command tolerates failure: no adb, no device
# and a hung adb call (each is under `timeout 8`) only mean that tick's guest
# sample says so and the loop carries on.

OUT="${1:-}"
if [ -z "$OUT" ]; then
  echo "usage: emulator_watch.sh <outdir>" >&2
  exit 2
fi
mkdir -p "$OUT" || exit 1

PKG="app.fayad.ludo"

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

# Looked up on every tick: the emulator action may install platform-tools
# after this script has started, and PATH may not carry it on the runner.
find_adb() {
  local c
  if c=$(command -v adb 2>/dev/null) && [ -n "$c" ]; then
    echo "$c"
    return 0
  fi
  for c in \
    "${ANDROID_HOME:-/nonexistent}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-/nonexistent}/platform-tools/adb" \
    /usr/local/lib/android/sdk/platform-tools/adb; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

host_sample() {
  {
    echo "=== $(ts) host"
    echo "--- free -m"
    free -m 2>&1
    echo "--- loadavg"
    cat /proc/loadavg 2>&1
    echo "--- ps (rss in KiB)"
    # The bracketed first letter keeps these patterns from matching this
    # awk's own command line; emulator_watch is this script.
    ps -eo pid,ppid,rss,vsz,pcpu,etime,stat,cmd 2>&1 |
      awk 'NR == 1 || (/[q]emu-system|[e]mulator/ && !/emulator_watch/)'
  } >> "$OUT/host.log" 2>&1
}

host_loop() {
  while :; do
    host_sample
    sleep 5
  done
}

# The first `App Summary` block and the TOTAL rows of `dumpsys meminfo <pkg>`.
# Layout read from the captured dump in flutter_tools'
# lib/src/android/android_device.dart (parseMeminfoDump): an `Uptime:` line,
# `** MEMINFO in pid N [pkg] **`, a table ending in a `TOTAL` row, then
# ` App Summary` (Java Heap, Native Heap, Code, Stack, Graphics, Private
# Other, System, `TOTAL:`) up to a blank line and ` Objects`. That dump is
# from an older Android; newer ones add Rss columns and name the summary row
# `TOTAL PSS:`, so rows are matched on a leading TOTAL either way. If no
# `App Summary` is found at all, the first 40 lines are kept instead.
cut_meminfo() {
  local dump="$1"
  if printf '%s\n' "$dump" | grep -q 'App Summary'; then
    printf '%s\n' "$dump" | awk '
      /^Uptime:/ || /MEMINFO in pid/ { print; next }
      /App Summary/ { insum = 1 }
      insum && /^ *Objects/ { insum = 0 }
      insum { print; if (++n >= 25) insum = 0; next }
      /^ *TOTAL/ { print }
    '
  else
    printf '%s\n' "$dump" | head -n 40
  fi
}

guest_sample() {
  local adb state pid dump
  {
    echo "=== $(ts) guest"
    if ! adb=$(find_adb); then
      echo "adb: not found"
      echo "device: none attached or not online"
    else
      state=$(timeout 8 "$adb" get-state 2>&1 | tr -d '\r')
      echo "get-state: ${state:-<empty>}"
      if [ "$state" = "device" ]; then
        echo "device: online"
        echo "--- /proc/meminfo (first 6 lines)"
        timeout 8 "$adb" shell head -n 6 /proc/meminfo 2>&1 | tr -d '\r'
        pid=$(timeout 8 "$adb" shell pidof "$PKG" 2>&1 | tr -d '\r')
        echo "pidof $PKG: ${pid:-none}"
        case "$pid" in
          '' | *[!0-9\ ]*) ;;
          *)
            dump=$(timeout 8 "$adb" shell dumpsys meminfo "$PKG" 2>&1 | tr -d '\r')
            echo "--- dumpsys meminfo $PKG (summary)"
            if [ -n "$dump" ]; then
              cut_meminfo "$dump"
            else
              echo "dumpsys: no output"
            fi
            ;;
        esac
      else
        echo "device: none attached or not online"
      fi
    fi
  } >> "$OUT/guest.log" 2>&1
}

guest_loop() {
  while :; do
    guest_sample
    sleep 10
  done
}

# Waits for a device, then streams logcat into logcat.txt. When adb drops
# (emulator death, server restart) the stream ends; the loop writes a marker
# and starts again. A restart replays the device's buffer, so lines can repeat
# after a marker.
logcat_loop() {
  local adb pid n=0 state rc
  pid=""
  trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' TERM INT
  while :; do
    adb=$(find_adb) || { sleep 5; continue; }
    state=$(timeout 8 "$adb" get-state 2>/dev/null | tr -d '\r')
    if [ "$state" != "device" ]; then
      sleep 5
      continue
    fi
    n=$((n + 1))
    echo "--- $(ts) logcat start #$n" >> "$OUT/logcat.txt"
    "$adb" logcat -b main,system,crash,events -v threadtime,UTC >> "$OUT/logcat.txt" 2>&1 &
    pid=$!
    wait "$pid"
    rc=$?
    echo "--- $(ts) logcat ended rc=$rc" >> "$OUT/logcat.txt"
    pid=""
    sleep 2
  done
}

echo "$(ts) watcher start, out=$OUT, adb=$(find_adb || echo none)"

host_loop &
HOST_PID=$!
guest_loop &
GUEST_PID=$!
logcat_loop &
LOGCAT_PID=$!

stop() {
  trap - TERM INT
  kill -TERM "$HOST_PID" "$GUEST_PID" "$LOGCAT_PID" 2>/dev/null
  wait 2>/dev/null
  echo "$(ts) watcher stop"
  exit 0
}
trap stop TERM INT

wait
