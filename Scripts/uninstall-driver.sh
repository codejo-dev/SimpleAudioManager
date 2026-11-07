#!/bin/bash
# Removes the SimpleAudioManager HAL driver and restarts Core Audio.
set -euo pipefail
DEST="/Library/Audio/Plug-Ins/HAL/SimpleAudioManager.driver"
if [[ -d "$DEST" ]]; then
    sudo rm -rf "$DEST"
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod
    echo "Driver removed."
else
    echo "Driver is not installed."
fi
