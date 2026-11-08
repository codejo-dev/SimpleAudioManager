#!/bin/bash
# Builds a release of Simple Audio Manager into dist/.
#
#   Scripts/build-release.sh <version> [build-number]
#   Scripts/build-release.sh v1.2.0 42
#
# Output:
#   dist/SimpleAudioManager-<version>.zip         app + install/uninstall scripts
#   dist/SimpleAudioManager-<version>.zip.sha256
#
# Signing (optional, environment):
#   SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"; ad-hoc when unset
#   DEVELOPMENT_TEAM   team ID for that identity
# Notarization (optional, needs SIGNING_IDENTITY):
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (app-specific password)
set -euo pipefail

VERSION="${1:?usage: Scripts/build-release.sh <version> [build-number]}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${2:-1}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Version must look like 1.2.3 or 1.2.3-beta.1 (got: $VERSION)" >&2
    exit 1
fi
# CFBundleShortVersionString allows only digits and dots.
MARKETING_VERSION="${VERSION%%[-+]*}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="$ROOT/build/release"
DIST="$ROOT/dist"
APP_NAME="Simple Audio Manager.app"
ZIP_NAME="SimpleAudioManager-$VERSION.zip"

echo "==> Simple Audio Manager $VERSION (build $BUILD_NUMBER)"
xcodebuild -version | head -1

command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q

SIGN_ARGS=(CODE_SIGN_IDENTITY="${SIGNING_IDENTITY:--}" CODE_SIGN_STYLE=Manual)
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    echo "==> Signing with: $SIGNING_IDENTITY"
    SIGN_ARGS+=(DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp")
else
    echo "==> Ad-hoc signing (no SIGNING_IDENTITY set)"
fi

echo "==> Building"
rm -rf "$BUILD_DIR"
xcodebuild \
    -project SimpleAudioManager.xcodeproj \
    -scheme SimpleAudioManager \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    SYMROOT="$BUILD_DIR" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${SIGN_ARGS[@]}" \
    build -quiet

APP="$BUILD_DIR/Release/$APP_NAME"
DRIVER="$APP/Contents/Resources/SimpleAudioManager.driver"
[[ -d "$APP" && -d "$DRIVER" ]] || { echo "Build output missing: $APP" >&2; exit 1; }

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
echo "    app:    $(lipo -archs "$APP/Contents/MacOS/Simple Audio Manager")"
echo "    driver: $(lipo -archs "$DRIVER/Contents/MacOS/SimpleAudioManager")"
echo "    version: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info" CFBundleVersion))"

if [[ -n "${SIGNING_IDENTITY:-}" && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    echo "==> Notarizing"
    NOTARY_ZIP="$BUILD_DIR/notarize.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" \
        --wait
    xcrun stapler staple "$APP"
    rm -f "$NOTARY_ZIP"
fi

echo "==> Packaging"
STAGE_ROOT="$BUILD_DIR/stage"
STAGE="$STAGE_ROOT/Simple Audio Manager $VERSION"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/$APP_NAME"
cp Scripts/release/install.sh Scripts/release/uninstall.sh "$STAGE/"
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
ditto App/Resources/Licenses "$STAGE/Licenses"
cat > "$STAGE/README.txt" <<TXT
Simple Audio Manager $VERSION
https://github.com/codejo-dev/SimpleAudioManager

Install
  Open Terminal in this folder and run:  ./install.sh
  It copies the app to /Applications, installs the audio driver and restarts
  Core Audio (sound drops for about a second). You need an administrator
  password.

Uninstall
  ./uninstall.sh            removes the app and the driver
  ./uninstall.sh --purge    also removes settings, icons and saved proxies

MIT License, see LICENSE. Third-party licenses: THIRD_PARTY_NOTICES.md and Licenses/.
TXT

rm -f "$DIST/$ZIP_NAME" "$DIST/$ZIP_NAME.sha256"
(cd "$STAGE_ROOT" && ditto -c -k --sequesterRsrc --keepParent "Simple Audio Manager $VERSION" "$DIST/$ZIP_NAME")
(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

echo "==> Done"
ls -lh "$DIST/$ZIP_NAME"
cat "$DIST/$ZIP_NAME.sha256"
