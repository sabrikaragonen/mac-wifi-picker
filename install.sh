#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/WiFi Picker.app"
AGENTS="$HOME/Library/LaunchAgents"
MENU_PLIST="$AGENTS/com.wifipicker.menu.plist"
OLD_WORKER_PLIST="$AGENTS/com.wifipicker.plist"
LOGS="$HOME/Library/Logs"
DOMAIN="gui/$(id -u)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's Command Line Tools first: xcode-select --install"
  exit 1
fi

mkdir -p "$HOME/Applications" "$AGENTS" "$LOGS"
BUILD_DIR=$(mktemp -d "$HOME/Applications/.wifi-picker-build.XXXXXX")
NEW_APP="$BUILD_DIR/WiFi Picker.app"
APP_BACKUP="$HOME/Applications/.WiFi Picker.previous.app"
PLIST_TEMP="$AGENTS/.com.wifipicker.menu.plist.tmp"

cleanup() {
  rm -rf "$BUILD_DIR"
  rm -f "$PLIST_TEMP"
}
trap cleanup EXIT

mkdir -p "$NEW_APP/Contents/MacOS" "$NEW_APP/Contents/Resources"
MACOSX_DEPLOYMENT_TARGET=12.0 swiftc "$ROOT/src/WiFiPicker.swift" \
  -O \
  -o "$NEW_APP/Contents/MacOS/WiFiPicker" \
  -framework Cocoa \
  -framework CoreWLAN \
  -framework CoreLocation \
  -framework UserNotifications

cat > "$NEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WiFi Picker</string>
  <key>CFBundleDisplayName</key><string>WiFi Picker</string>
  <key>CFBundleIdentifier</key><string>local.wifipicker.menubar</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>WiFiPicker</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>WiFi Picker scans nearby saved networks to select a better connection.</string>
</dict>
</plist>
PLIST

plutil -lint "$NEW_APP/Contents/Info.plist" >/dev/null
# Keep the designated requirement stable across local rebuilds so macOS does not
# treat each update as a brand-new app for Location/Notification permissions.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "local.wifipicker.menubar"' \
  "$NEW_APP" >/dev/null

cat > "$PLIST_TEMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.wifipicker.menu</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/WiFiPicker</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/wifi-picker-menu.out</string>
  <key>StandardErrorPath</key><string>$LOGS/wifi-picker-menu.err</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST_TEMP" >/dev/null

# Stop both the v4 shell worker and the existing menu process before replacement.
launchctl bootout "$DOMAIN/com.wifipicker" 2>/dev/null || true
launchctl bootout "$DOMAIN/com.wifipicker.menu" 2>/dev/null || true
launchctl bootout "$DOMAIN" "$OLD_WORKER_PLIST" 2>/dev/null || true
launchctl bootout "$DOMAIN" "$MENU_PLIST" 2>/dev/null || true

rm -f "$OLD_WORKER_PLIST" "$HOME/.local/bin/wifi-picker"

rm -rf "$APP_BACKUP"
if [[ -d "$APP" ]]; then mv "$APP" "$APP_BACKUP"; fi
if ! mv "$NEW_APP" "$APP"; then
  if [[ -d "$APP_BACKUP" ]]; then mv "$APP_BACKUP" "$APP"; fi
  echo "Could not install the new app; the previous version was restored."
  exit 1
fi
rm -rf "$APP_BACKUP"
mv "$PLIST_TEMP" "$MENU_PLIST"

if ! launchctl bootstrap "$DOMAIN" "$MENU_PLIST"; then
  echo "The app was built, but its login agent could not be started."
  echo "Try opening it manually: open \"$APP\""
  exit 1
fi

echo "WiFi Picker installed and started."
echo "Allow Location access when macOS asks; it is required to scan nearby SSIDs."
