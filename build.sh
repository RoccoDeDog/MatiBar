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
  <key>CFBundleVersion</key><string>1.0.1</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
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

# ad-hoc signature (lets macOS run a locally built app without a Developer ID)
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built $APP"
