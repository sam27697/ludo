#!/usr/bin/env bash
# Runs integration_test/motion_test.dart with full animations enabled, recording
# the emulator screen to segmented MP4 files.
#
# Flutter drive builds and installs the app before launching tests. Waiting for
# the app PID keeps build time out of the video segments. Android screenrecord
# caps each capture at 180s, so the background recorder captures consecutive
# 170s chunks until test execution completes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$CLIENT_DIR"

mkdir -p motion

# Explicitly set animation scales to 1 so the emulator runs full-motion
# animations rather than the reduced-motion scales used in screenshots.
adb shell settings put global window_animation_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global animator_duration_scale 1

{
  echo "window_animation_scale: $(adb shell settings get global window_animation_scale | tr -d '\r')"
  echo "transition_animation_scale: $(adb shell settings get global transition_animation_scale | tr -d '\r')"
  echo "animator_duration_scale: $(adb shell settings get global animator_duration_scale | tr -d '\r')"
} > motion/animation-scales.txt

STOP_FILE="$CLIENT_DIR/motion/.stop_recording"
rm -f "$STOP_FILE"

# Clean any existing recordings on device.
adb shell rm -f '/sdcard/motion_*.mp4' 2>/dev/null || true

# Background recorder: wait until the app process starts, then capture
# back-to-back 170-second segments until the stop file appears.
record_motion() {
  local app_found=false
  for ((i = 0; i < 1200; i++)); do
    if [ -f "$STOP_FILE" ]; then
      return 0
    fi
    local pid
    pid=$(adb shell pidof app.fayad.ludo 2>/dev/null | tr -d '\r[:space:]' || true)
    if [ -n "$pid" ]; then
      app_found=true
      break
    fi
    sleep 1
  done

  if [ "$app_found" = false ]; then
    echo "Timed out waiting for app.fayad.ludo process after 20 minutes" >&2
    return 0
  fi

  local n=0
  while [ ! -f "$STOP_FILE" ]; do
    local start_sec=$SECONDS
    adb shell screenrecord \
      --size 720x1280 \
      --bit-rate 4000000 \
      --time-limit 170 \
      "/sdcard/motion_${n}.mp4" || true
    n=$((n + 1))
    local elapsed=$(( SECONDS - start_sec ))
    if [ "$elapsed" -lt 2 ] && [ ! -f "$STOP_FILE" ]; then
      sleep 1
    fi
  done
}

record_motion &
RECORDER_PID=$!

# Run the motion test driver.
set +e
flutter drive \
  --profile \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/motion_test.dart \
  -d emulator-5554 2>&1 | tee motion/drive.log
drive_exit="${PIPESTATUS[0]}"
set -e

# Hold the final screen for 2s so the end state is captured in video.
sleep 2

# Signal recorder to stop and interrupt screenrecord to finalise the MP4 container.
touch "$STOP_FILE"

if ! adb shell pkill -INT screenrecord 2>/dev/null; then
  rec_pid=$(adb shell pidof screenrecord 2>/dev/null | tr -d '\r[:space:]' || true)
  if [ -n "$rec_pid" ]; then
    adb shell kill -2 "$rec_pid" 2>/dev/null || true
  fi
fi

# Wait up to 30s for the recorder loop to exit cleanly.
wait_timeout=30
while kill -0 "$RECORDER_PID" 2>/dev/null && [ "$wait_timeout" -gt 0 ]; do
  sleep 1
  wait_timeout=$((wait_timeout - 1))
done
if kill -0 "$RECORDER_PID" 2>/dev/null; then
  echo "Recorder loop did not finish within 30s; terminating..." >&2
  kill "$RECORDER_PID" 2>/dev/null || true
fi
wait "$RECORDER_PID" 2>/dev/null || true
rm -f "$STOP_FILE"

# Pull all recorded segments from device into motion/
remote_files=$(adb shell 'ls -1 /sdcard/motion_*.mp4 2>/dev/null' | tr -d '\r' || true)
for rf in $remote_files; do
  case "$rf" in
    /sdcard/motion_*.mp4)
      adb pull "$rf" motion/ || true
      ;;
  esac
done

# Print file list with sizes either way.
echo "=== motion/ artifacts ==="
ls -la motion/

has_large_mp4=false
shopt -s nullglob
mp4_files=(motion/*.mp4)
shopt -u nullglob

for mp4 in "${mp4_files[@]}"; do
  size=$(wc -c < "$mp4")
  echo "MP4: $mp4 ($size bytes)"
  if [ "$size" -gt 204800 ]; then
    has_large_mp4=true
  fi
done

if [ "$drive_exit" -ne 0 ]; then
  echo "flutter drive failed with exit code $drive_exit" >&2
  exit "$drive_exit"
fi

if [ "$has_large_mp4" = false ]; then
  echo "No MP4 file in motion/ is larger than 200 KB" >&2
  exit 1
fi
