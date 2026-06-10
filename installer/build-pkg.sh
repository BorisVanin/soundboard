#!/bin/bash
#
# Build a double-clickable macOS installer (.pkg) that installs:
#   • Soundboard.app             → /Applications
#   • SoundboardDriver.driver    → /Library/Audio/Plug-Ins/HAL
# and restarts coreaudiod (postinstall) so the HAL plug-in loads immediately.
#
# LOCAL build: both bundles are ad-hoc signed (codesign -s -). That installs and
# runs on THIS machine. To distribute to other Macs you must instead sign with a
# "Developer ID Application" identity, sign the .pkg with "Developer ID Installer",
# and notarize+staple — see the NOTARIZATION section at the bottom of this file.
#
# Usage:  installer/build-pkg.sh        (or: make installer)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/installer/.build"
STAGE="$ROOT/installer/.stage"
OUT="$ROOT/installer/dist"
APP="Soundboard.app"
DRIVER="SoundboardDriver.driver"
VERSION="${VERSION:-1.0}"
PKG="$OUT/Soundboard-$VERSION.pkg"

rm -rf "$BUILD" "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Audio/Plug-Ins/HAL" "$OUT"

echo "==> generating Xcode projects"
( cd "$ROOT" && make generate >/dev/null )

echo "==> building app (Release, optimized)"
xcodebuild -workspace "$ROOT/Soundboard.xcworkspace" -scheme SoundboardApp \
    -configuration Release -derivedDataPath "$BUILD" \
    -destination "platform=macOS,arch=arm64" \
    ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "==> building driver (Release)"
xcodebuild -project "$ROOT/LoopbackDriver/LoopbackDriver.xcodeproj" -scheme SoundboardDriver \
    -configuration Release -derivedDataPath "$BUILD" \
    -destination "platform=macOS,arch=arm64" \
    ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build >/dev/null

APP_BUILT="$BUILD/Build/Products/Release/$APP"
DRIVER_BUILT="$BUILD/Build/Products/Release/$DRIVER"
[[ -d "$APP_BUILT" ]]    || { echo "app not found:    $APP_BUILT"; exit 1; }
[[ -d "$DRIVER_BUILT" ]] || { echo "driver not found: $DRIVER_BUILT"; exit 1; }

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$DRIVER_BUILT"
codesign --force --deep --sign - \
    --entitlements "$ROOT/SoundboardApp/SoundboardApp.entitlements" "$APP_BUILT"

echo "==> staging payload"
cp -R "$APP_BUILT"    "$STAGE/Applications/"
cp -R "$DRIVER_BUILT" "$STAGE/Library/Audio/Plug-Ins/HAL/"

echo "==> building $PKG"
chmod +x "$ROOT/installer/scripts/postinstall"
pkgbuild \
    --root "$STAGE" \
    --identifier ca.borisvanin.soundboard.pkg \
    --version "$VERSION" \
    --scripts "$ROOT/installer/scripts" \
    --install-location / \
    --ownership recommended \
    "$PKG"

echo
echo "✅ built $PKG"
echo "   Install:   sudo installer -pkg \"$PKG\" -target /"
echo "   or double-click it in Finder (it will prompt for your password)."

# ---------------------------------------------------------------------------
# NOTARIZATION (to distribute to OTHER Macs) — not done here (local/ad-hoc build):
#   1. Sign both bundles with Developer ID instead of ad-hoc, e.g.
#        codesign --force --options runtime --timestamp \
#          --sign "Developer ID Application: NAME (TEAMID)" "$APP_BUILT"
#        (same for the .driver)
#   2. Build the pkg, then sign it:
#        productbuild --component ... OR pkgbuild ... then
#        productsign --sign "Developer ID Installer: NAME (TEAMID)" in.pkg out.pkg
#   3. Notarize + staple:
#        xcrun notarytool submit out.pkg --apple-id you@id --team-id TEAMID \
#          --password APP_SPECIFIC_PW --wait
#        xcrun stapler staple out.pkg
# ---------------------------------------------------------------------------
