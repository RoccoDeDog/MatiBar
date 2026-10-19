#!/bin/sh
# Builds MatiBar.app from matibar.m (needs Xcode Command Line Tools).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
APP="MatiBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

clang -fobjc-arc -O2 -mmacosx-version-min=12.0 \
  -framework AppKit -framework Foundation -framework QuartzCore -framework CoreGraphics -framework IOKit \
  -framework CoreAudio -framework CoreLocation -framework Accelerate \
  -F/System/Library/PrivateFrameworks -framework DFRFoundation \
  matibar.m -o "$APP/Contents/MacOS/MatiBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MatiBar</string>
  <key>CFBundleDisplayName</key><string>MatiBar</string>
  <key>CFBundleIdentifier</key><string>com.mati.matibar</string>
  <key>CFBundleExecutable</key><string>MatiBar</string>
  <key>CFBundleVersion</key><string>1.0.2</string>
  <key>CFBundleShortVersionString</key><string>1.0.2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSLocationUsageDescription</key><string>MatiBar uses your location to show local weather, sunrise, sunset and the moon on the Touch Bar.</string>
  <key>NSAudioCaptureUsageDescription</key><string>MatiBar listens to the audio your Mac is playing (never the microphone) only while the hidden visualizer is open, to animate it on the Touch Bar. Nothing is recorded or saved.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>MatiBar uses your location to show local weather, sunrise, sunset and the moon on the Touch Bar.</string>
</dict>
</plist>
PLIST

# Signature. With a stable signing identity macOS keeps your permissions (Automation, Location,
# System Audio Recording) across rebuilds; an ad-hoc signature changes on every build, so macOS
# asks again each time. Uses $MATIBAR_SIGN_IDENTITY, or a certificate named "MatiBar Dev Signing"
# if you have one (a self-signed code-signing certificate is enough), otherwise ad-hoc.
ID="${MATIBAR_SIGN_IDENTITY:-}"
if [ -z "$ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"MatiBar Dev Signing"'; then
  ID="MatiBar Dev Signing"
  # optional local helper: unlock a dedicated dev keychain if its password file exists
  if [ -f "$HOME/.matibar-dev/pass" ]; then security unlock-keychain -p "$(cat "$HOME/.matibar-dev/pass")" matibar-dev.keychain 2>/dev/null || true; fi
fi
if [ -n "$ID" ] && codesign --force --deep -s "$ID" "$APP" 2>/dev/null; then
  echo "Signed with \"$ID\""
else
  [ -n "$ID" ] && echo "Warning: signing with \"$ID\" failed, using an ad-hoc signature (macOS may ask for permissions again)" >&2
  codesign --force --deep -s - "$APP" 2>/dev/null || true
fi

echo "Built $APP"
