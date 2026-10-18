#!/bin/sh
# Builds MatiBar, installs it to /Applications, enables full-width Touch Bar,
# and sets it to launch automatically at login.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

sh "$DIR/build.sh"

echo "Installing to /Applications ..."
pkill -x MatiBar 2>/dev/null || true; pkill -x matibar 2>/dev/null || true
rm -rf "/Applications/MatiBar.app"
cp -R "$DIR/MatiBar.app" "/Applications/MatiBar.app"

# Full-width Touch Bar (hides Apple's Control Strip so MatiBar fills the bar).
# Reverted by uninstall.sh.
defaults write com.apple.touchbar.agent PresentationModeGlobal -string app
killall ControlStrip 2>/dev/null || true

# Launch at login + keep running.
PLIST="$HOME/Library/LaunchAgents/com.mati.matibar.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mati.matibar</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/MatiBar.app/Contents/MacOS/MatiBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "MatiBar installed and running. It will start automatically at login."
echo "The first time you use the audio controls, macOS will ask permission to"
echo "control Spotify / Music (Automation) - approve it so playback works."
echo ""
echo "To remove it: ./uninstall.sh"
