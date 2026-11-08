#!/bin/bash
# Removes Simple Audio Manager and its audio driver.
#
#   ./uninstall.sh           remove the app and the driver, keep your settings
#   ./uninstall.sh --purge   also remove settings, icons and saved proxies
#
# Restarts Core Audio (sound drops for about a second); macOS falls back to
# another output if a proxy was selected. Asks for your administrator password.
set -euo pipefail

APP="/Applications/Simple Audio Manager.app"
BUNDLE_ID="dev.codejo.SimpleAudioManager"
DRIVER="/Library/Audio/Plug-Ins/HAL/SimpleAudioManager.driver"
EXECUTABLE="$APP/Contents/MacOS/Simple Audio Manager"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "Removing Simple Audio Manager$([[ $PURGE == 1 ]] && echo ' and all its settings')"
sudo -v

osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
pkill -x "Simple Audio Manager" >/dev/null 2>&1 || true

# Let the app remove its login item (and, with --purge, its proxies and
# settings) while the driver is still loaded.
if [[ -x "$EXECUTABLE" ]]; then
    if [[ $PURGE == 1 ]]; then
        "$EXECUTABLE" --prepare-uninstall --purge || true
    else
        "$EXECUTABLE" --prepare-uninstall || true
    fi
fi

if [[ -d "$DRIVER" ]]; then
    echo "Removing the audio driver..."
    sudo rm -rf "$DRIVER"
    echo "Restarting Core Audio..."
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod
fi

if [[ -d "$APP" ]]; then
    echo "Removing the app..."
    sudo rm -rf "$APP"
fi

if [[ $PURGE == 1 ]]; then
    rm -rf "$HOME/Library/Application Support/SimpleAudioManager"
    sudo rm -rf "/Users/Shared/SimpleAudioManager"
fi

echo "Simple Audio Manager has been removed."
