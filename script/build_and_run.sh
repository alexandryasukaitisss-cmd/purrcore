#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PurrCore"
BUNDLE_ID="${PURRCORE_BUNDLE_ID:-io.github.purrcore.PurrCore}"
MIN_SYSTEM_VERSION="14.0"
SIGNING_IDENTITY="${PURRCORE_SIGNING_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

PURRCORE_TARGET_EXECUTABLE="$APP_MACOS/$APP_NAME" swift -e '
import AppKit
import Foundation

guard let target = ProcessInfo.processInfo.environment["PURRCORE_TARGET_EXECUTABLE"] else {
    exit(2)
}
let applications = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.path == target
}
for application in applications {
    _ = application.terminate()
}
let deadline = Date().addingTimeInterval(5)
while Date() < deadline, applications.contains(where: { !$0.isTerminated }) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if applications.contains(where: { !$0.isTerminated }) {
    fputs("PurrCore: existing dist build did not terminate cleanly\n", stderr)
    exit(1)
}
'
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BIN_DIR/$APP_NAME" "$APP_MACOS/$APP_NAME"
cp "$BIN_DIR/purrcorectl" "$APP_RESOURCES/purrcorectl"
cp -R "$BIN_DIR/PurrCore_PurrCore.bundle" "$APP_RESOURCES/PurrCore_PurrCore.bundle"
cp "$BIN_DIR/purrcorectl" "$DIST_DIR/purrcorectl"
chmod +x "$APP_MACOS/$APP_NAME" "$APP_RESOURCES/purrcorectl" "$DIST_DIR/purrcorectl"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf "APPL????" >"$APP_CONTENTS/PkgInfo"
xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_RESOURCES/purrcorectl" >/dev/null
  codesign --force --sign - "$DIST_DIR/purrcorectl" >/dev/null
  codesign --force --sign - -i "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_RESOURCES/purrcorectl" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$DIST_DIR/purrcorectl" >/dev/null
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" -i "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build)
    ;;
  run)
    open_app
    ;;
  visual)
    /usr/bin/open -n "$APP_BUNDLE" --args --show-dashboard
    ;;
  menu)
    /usr/bin/open -n "$APP_BUNDLE" --args --show-menu
    ;;
  settings)
    /usr/bin/open -n "$APP_BUNDLE" --args --show-settings
    ;;
  --debug|debug)
    lldb -- "$APP_MACOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    pgrep -x "$APP_NAME" >/dev/null
    codesign --verify --deep --strict "$APP_BUNDLE"
    "$DIST_DIR/purrcorectl" status >/dev/null
    ;;
  *)
    echo "usage: $0 [run|visual|menu|settings|build|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
