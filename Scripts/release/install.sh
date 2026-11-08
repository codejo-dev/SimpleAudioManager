#!/bin/bash
# Installs Simple Audio Manager and its audio driver.
#
#   ./install.sh                 install the app next to this script
#   ./install.sh /path/to/App    install a specific copy of the app
#   ./install.sh --no-launch     do not open the app afterwards
#
# Puts the app in /Applications and the driver in /Library/Audio/Plug-Ins/HAL,
# then restarts Core Audio (sound drops for about a second). Asks for your
# administrator password.
set -euo pipefail

APP_NAME="Simple Audio Manager.app"
BUNDLE_ID="dev.codejo.SimpleAudioManager"
DRIVER_NAME="SimpleAudioManager.driver"
DEST_APP="/Applications/$APP_NAME"
DEST_DRIVER="/Library/Audio/Plug-Ins/HAL/$DRIVER_NAME"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/$APP_NAME"
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) SRC="$arg" ;;
    esac
done

if [[ ! -d "$SRC/Contents/Resources/$DRIVER_NAME" ]]; then
    echo "Could not find the app with its driver at: $SRC" >&2
    exit 1
fi

echo "Installing Simple Audio Manager"
echo "  app:    $DEST_APP"
echo "  driver: $DEST_DRIVER"
echo "Core Audio restarts at the end, so sound drops for a moment."
sudo -v

# Quit a running copy so it can be replaced.
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
pkill -x "Simple Audio Manager" >/dev/null 2>&1 || true

echo "Copying the app..."
sudo rm -rf "$DEST_APP"
sudo ditto "$SRC" "$DEST_APP"
# Downloaded copies carry a quarantine flag; the app is not notarized unless
# the release was built with a Developer ID, so remove it.
sudo xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "Installing the audio driver..."
sudo rm -rf "$DEST_DRIVER"
sudo ditto "$DEST_APP/Contents/Resources/$DRIVER_NAME" "$DEST_DRIVER"
sudo chown -R root:wheel "$DEST_DRIVER"
sudo chmod -R go-w "$DEST_DRIVER"
sudo xattr -dr com.apple.quarantine "$DEST_DRIVER" 2>/dev/null || true

echo "Restarting Core Audio..."
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod

echo "Done."
if [[ "$LAUNCH" == 1 ]]; then
    sleep 2
    open "$DEST_APP"
fi
