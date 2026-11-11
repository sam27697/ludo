#!/usr/bin/env bash
# Plays integration_test/motion_test.dart in profile mode on the emulator with
# no screen recording and writes the FrameTiming of every rendered frame to
# perf/perf-<locale>-seat<seat>.json (see integration_test/perf_probe_test.dart).
# perf/device.txt says what the numbers were measured on.

set -euo pipefail

# en or ar. Default en when unset.
MOTION_LOCALE="${MOTION_LOCALE-en}"
case "$MOTION_LOCALE" in
  en|ar) ;;
  *)
    echo "MOTION_LOCALE must be en or ar, got: ${MOTION_LOCALE}" >&2
    exit 2
    ;;
esac
echo "MOTION_LOCALE=${MOTION_LOCALE}"

# 0 or 2. A two-player room is seated 0 and 2.
MOTION_SEAT="${MOTION_SEAT-0}"
case "$MOTION_SEAT" in
  0|2) ;;
  *)
    echo "MOTION_SEAT must be 0 or 2, got: ${MOTION_SEAT}" >&2
    exit 2
    ;;
esac
echo "MOTION_SEAT=${MOTION_SEAT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$CLIENT_DIR"

# A stale report from an earlier run must not pass for this one.
rm -rf perf
mkdir -p perf

# Full-motion animation scales, as tool/record_motion.sh sets them.
adb shell settings put global window_animation_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global animator_duration_scale 1

{
  echo "abi: $(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "emulator nproc: $(adb shell nproc | tr -d '\r')"
  echo "display refresh:"
  adb shell dumpsys display | grep -i 'refresh\|fps' | head -5 || true
  echo "host nproc: $(nproc)"
  echo "host cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  echo "animation scales: $(adb shell settings get global window_animation_scale | tr -d '\r') $(adb shell settings get global transition_animation_scale | tr -d '\r') $(adb shell settings get global animator_duration_scale | tr -d '\r')"
} > perf/device.txt
cat perf/device.txt

set +e
flutter drive \
  --profile \
  --driver=test_driver/perf_probe_driver.dart \
  --target=integration_test/perf_probe_test.dart \
  --dart-define=MOTION_LOCALE="$MOTION_LOCALE" \
  --dart-define=MOTION_SEAT="$MOTION_SEAT" \
  -d emulator-5554 2>&1 | tee perf/drive.log
drive_exit="${PIPESTATUS[0]}"
set -e

if [ "$drive_exit" -ne 0 ]; then
  echo "flutter drive failed with exit code $drive_exit" >&2
  exit "$drive_exit"
fi

report="perf/perf-${MOTION_LOCALE}-seat${MOTION_SEAT}.json"
if [ ! -s "$report" ]; then
  echo "missing report: $report" >&2
  exit 1
fi

mode="$(sed -n 's/^  "mode": "\([a-z]*\)",\{0,1\}$/\1/p' "$report")"
if [ "$mode" != "profile" ]; then
  echo "report mode is '${mode}', not profile; the numbers would not mean what the probe says" >&2
  exit 1
fi

echo "=== perf/ artifacts ==="
ls -la perf/
