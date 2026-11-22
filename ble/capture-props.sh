#!/bin/bash
# capture-props.sh — run the app with the property-capture Frida hook and grab the log.
# Usage: ./capture-props.sh [adb-id] [seconds]
#   adb-id: your USB serial from `adb devices` (or IP:PORT for wireless)
set -e
ADB_ID="${1:?usage: capture-props.sh <adb-serial> [seconds]}"
SECONDS_RUN="${2:-240}"
HOOK_FILE="${HOOK_FILE:-repack/efhook-props.js}"
ADB="adb -s $ADB_ID"
OUT="efhook-props-capture.txt"
cd "$(dirname "$0")/.."

echo "[1/5] pushing hook script to the app's files dir"
$ADB push "$HOOK_FILE" /data/local/tmp/efhook.js
$ADB shell "chmod 644 /data/local/tmp/efhook.js"
$ADB shell "run-as com.ecoflow cp /data/local/tmp/efhook.js files/efhook.js"
$ADB shell "run-as com.ecoflow chmod 644 files/efhook.js"
$ADB shell "run-as com.ecoflow head -c 60 files/efhook.js"

echo "[2/5] clearing logcat + force-stopping app"
$ADB logcat -c
$ADB shell am force-stop com.ecoflow
sleep 2

echo "[3/5] starting app (screen on, stay awake)"
$ADB shell svc power stayon true
$ADB shell input keyevent KEYCODE_WAKEUP
LAUNCH=$($ADB shell cmd package resolve-activity --brief com.ecoflow | tail -1)
echo "launcher: $LAUNCH"
$ADB shell am start -n "$LAUNCH" || $ADB shell monkey -p com.ecoflow -c android.intent.category.LAUNCHER 1

echo "[4/5] capturing logcat for ${SECONDS_RUN}s (keep the app on the device page)"
$ADB logcat -s wrap.sh -v time > "ble/$OUT" &
LOGCAT_PID=$!
sleep "$SECONDS_RUN"
kill $LOGCAT_PID 2>/dev/null || true

echo "[5/5] pulling capture"
$ADB shell svc power stayon false
$ADB pull "/sdcard/Download" >/dev/null 2>&1 || true
wc -l "ble/$OUT"
echo "done -> ble/$OUT"
