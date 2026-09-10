#!/bin/bash
set -u

DOMAIN="gui/$(id -u)"
MENU_PLIST="$HOME/Library/LaunchAgents/com.wifipicker.menu.plist"
OLD_WORKER_PLIST="$HOME/Library/LaunchAgents/com.wifipicker.plist"

launchctl bootout "$DOMAIN/com.wifipicker" 2>/dev/null || true
launchctl bootout "$DOMAIN/com.wifipicker.menu" 2>/dev/null || true
launchctl bootout "$DOMAIN" "$OLD_WORKER_PLIST" 2>/dev/null || true
launchctl bootout "$DOMAIN" "$MENU_PLIST" 2>/dev/null || true

rm -f "$OLD_WORKER_PLIST" "$MENU_PLIST" "$HOME/.local/bin/wifi-picker"
rm -rf "$HOME/Applications/WiFi Picker.app"

echo "WiFi Picker removed. Settings and logs were kept."
