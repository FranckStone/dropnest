#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
bash scripts/build-rust.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -debug-info-format none -c "$CONFIG"
BIN_DIR="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c "$CONFIG" --show-bin-path)"
APP="build/DropNest.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DropNest" "$APP/Contents/MacOS/DropNest.next"
mv -f "$APP/Contents/MacOS/DropNest.next" "$APP/Contents/MacOS/DropNest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift build
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.frank.dropnest "$APP"
codesign --verify --strict "$APP"
echo "已生成：$(pwd)/$APP"
