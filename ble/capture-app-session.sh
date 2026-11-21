#!/bin/zsh
# Capture EcoFlow app BLE session: logcat (session key!) + btsnoop HCI frames.
# Usage: ./capture-app-session.sh <phone-ip>:<adb-port>
# e.g.   ./capture-app-session.sh <phone-ip>:<adb-port>

set -e
ADDR="$1"
if [ -z "$ADDR" ]; then
  echo "usage: $0 <phone-ip>:<adb-port>"; exit 1
fi

OUT="$(cd "$(dirname "$0")" && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== connecting adb =="
adb connect "$ADDR"
adb devices

echo
echo "== enabling HCI snoop (requires developer options already enabled) =="
adb shell settings put secure bluetooth_hci_log 1 2>/dev/null || true

echo "== clearing logcat =="
adb logcat -c

echo
echo ">>> NOW ON THE PHONE: toggle Bluetooth OFF then ON, then open the EcoFlow app"
echo ">>> and connect to the E980. Wait ~30 seconds so data streams."
echo
read "REPLY?Press ENTER after the app is connected and streaming..."

echo "== dumping logcat =="
adb logcat -d -v time > "$OUT/ef-logcat-$STAMP.txt"
echo "saved: $OUT/ef-logcat-$STAMP.txt  ($(wc -l < "$OUT/ef-logcat-$STAMP.txt") lines)"

echo "== pulling btsnoop =="
for P in /data/misc/bluetooth/logs/btsnoop_hci.log /sdcard/MIUI/debug_log/btsnoop_hci.log /data/misc/blt/btsnoop_hci.log; do
  if adb shell "test -f $P" 2>/dev/null; then
    adb pull "$P" "$OUT/btsnoop-$STAMP.log" && break
  fi
done
ls -la "$OUT"/btsnoop-$STAMP.log 2>/dev/null || echo "btsnoop not found at usual paths — tell me your phone model path"

echo "== session key lines found in logcat: =="
grep -aE 'appPriKey|sessionKey|sRand|shareKey|payloadDecrypt' "$OUT/ef-logcat-$STAMP.txt" | head -20

echo "DONE. Tell the agent the files are ready."
