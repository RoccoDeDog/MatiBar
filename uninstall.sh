#!/bin/sh
# Removes MatiBar and restores the normal Apple Touch Bar.
PLIST="$HOME/Library/LaunchAgents/com.mati.matibar.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -x MatiBar 2>/dev/null || true
rm -rf "/Applications/MatiBar.app"

# Restore Apple's Control Strip (brightness / volume / Siri).
defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip
killall ControlStrip 2>/dev/null || true

echo "MatiBar uninstalled. The normal Touch Bar is back."
