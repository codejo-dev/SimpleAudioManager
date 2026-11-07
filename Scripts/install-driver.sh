#!/bin/bash
# Installs the SimpleAudioManager HAL driver and restarts Core Audio.
# Usage: Scripts/install-driver.sh [path/to/SimpleAudioManager.driver]
# Needs your administrator password (sudo). Audio drops for ~1 second.
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/Debug/SimpleAudioManager.driver}"
DEST="/Library/Audio/Plug-Ins/HAL/SimpleAudioManager.driver"

if [[ ! -d "$SRC" ]]; then
    echo "Driver not found at $SRC. Build it first: make driver" >&2
    exit 1
fi

echo "Installing $SRC -> $DEST"
sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo chmod -R go-w "$DEST"

echo "Restarting Core Audio..."
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod
echo "Done. Check: swift run --package-path Packages/SAMKit samctl status"
