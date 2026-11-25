#!/bin/bash
# build.sh — build the GUI, assemble the .app bundle, ad-hoc sign, run.
set -e
cd "$(dirname "$0")"

echo "== swift build (release) =="
swift build -c release --product EcoFlowGUI

APP="build/EcoFlow.app"
BIN=".build/release/EcoFlowGUI"

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EcoFlowGUI"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== codesign (ad-hoc) =="
codesign --force --deep --sign - "$APP"

echo "== done: $APP =="
if [ "$1" == "--run" ]; then
    open "$APP"
fi
