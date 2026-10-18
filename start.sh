#!/bin/sh
# Enciende MatiBar a ancho completo (tapa el control strip de Apple)
DIR="$(cd "$(dirname "$0")" && pwd)"
defaults write com.apple.touchbar.agent PresentationModeGlobal -string app
killall ControlStrip 2>/dev/null
sleep 1
pkill -x matibar 2>/dev/null; sleep 0.5
nohup "$DIR/matibar" >/tmp/matibar.log 2>&1 &
echo "MatiBar encendida (PID $!)."
