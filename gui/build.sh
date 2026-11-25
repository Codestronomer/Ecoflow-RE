#!/bin/bash
# build.sh — build the GUI, assemble the .app bundle, ad-hoc sign, run.
#
# Examples:
#   ./build.sh                  # build (release), assemble EcoFlow.app, launch with open
#   ./build.sh --skip-run       # build only
#   ./build.sh --logs           # build, then run the inner binary streaming stdout/stderr
#                               # (use in a background shell — it blocks until the app quits)
#   ./build.sh --run            # legacy alias: build + open
#
# Note: this project builds with SwiftPM + manual bundle assembly because the
# machine has Command Line Tools only. When full Xcode + Tuist are installed,
# migrate to the appkit-dev-workflow build-and-run.sh (tuist generate + xcodebuild).
set -euo pipefail
cd "$(dirname "$0")"

MODE="open"   # open | skip | logs
for arg in "$@"; do
  case "$arg" in
    --skip-run) MODE="skip" ;;
    --logs)     MODE="logs" ;;
    --run)      MODE="open" ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

echo "== swift build (release) =="
swift build -c release --product EcoFlowGUI

APP="build/EcoFlow.app"
BIN=".build/release/EcoFlowGUI"

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EcoFlowGUI"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "(no icon)"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== codesign (ad-hoc) =="
codesign --force --deep --sign - "$APP"

echo "== done: $APP =="

case "$MODE" in
  skip) ;;
  open) open "$APP" ;;
  logs)
    echo "== running in foreground (stdout/stderr streamed; Cmd-Q or kill to stop) =="
    exec "$APP/Contents/MacOS/EcoFlowGUI"
    ;;
esac
