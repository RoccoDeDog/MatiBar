#!/bin/sh
# Apaga MatiBar y restaura el Touch Bar normal de Apple (brillo/volumen/Siri)
pkill -x matibar 2>/dev/null
defaults write com.apple.touchbar.agent PresentationModeGlobal -string appWithControlStrip
killall ControlStrip 2>/dev/null
echo "MatiBar apagada. Touch Bar normal restaurado."
