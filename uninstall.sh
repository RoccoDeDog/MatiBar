#!/bin/sh
# Removes MatiBar and restores the normal Apple Touch Bar.
PLIST="$HOME/Library/LaunchAgents/com.mati.matibar.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
GPLIST="$HOME/Library/LaunchAgents/com.mati.matibar.guard.plist"
launchctl unload "$GPLIST" 2>/dev/null || true
rm -f "$GPLIST"
pkill -x MatiBar 2>/dev/null || true; pkill -x matibar 2>/dev/null || true
# If a blackout was active, give the screen and keyboard back before removing anything.
MARKER="$HOME/Library/Application Support/MatiBar/blackout.json"
if [ -f "$MARKER" ] && [ -x "/Applications/MatiBar.app/Contents/MacOS/MatiBar" ]; then
  "/Applications/MatiBar.app/Contents/MacOS/MatiBar" --guard || true
fi
rm -rf "/Applications/MatiBar.app"
rm -rf "$HOME/Library/Application Support/MatiBar"

# Restore Apple's Control Strip (brightness / volume / Siri).
defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip
killall ControlStrip 2>/dev/null || true

echo "MatiBar uninstalled. The normal Touch Bar is back."
