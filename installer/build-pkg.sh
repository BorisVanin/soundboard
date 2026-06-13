#!/bin/bash
#
# Build a double-clickable macOS installer (.pkg) that installs:
#   • Soundboard.app             → /Applications
#   • SoundboardDriver.driver    → /Library/Audio/Plug-Ins/HAL
# and restarts coreaudiod (postinstall) so the HAL plug-in loads immediately.
#
# Xcode signs the bundles during the Release build (per project.yml): the app +
# its embedded frameworks and the driver are signed with "Developer ID
# Application" (hardened runtime, secure timestamp). This script only signs the
# .pkg itself with "Developer ID Installer" — the identities required to
# distribute outside the Mac App Store. The installer identity defaults to the
# single Developer ID Installer cert in your keychain; override with the env var
# below if you have more than one. To ship to other Macs, notarize + staple the
# .pkg — see the NOTARIZATION section at the bottom of this file.
#
# The finished .pkg lands in the project-root dist/ folder.
#
# Usage:  installer/build-pkg.sh        (or: make installer)
#         INSTALLER_SIGN_ID="Developer ID Installer: NAME (TEAMID)" \
#           installer/build-pkg.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/installer/.build"
STAGE="$ROOT/installer/.stage"
OUT="$ROOT/dist"
APP="Soundboard.app"
DRIVER="SoundboardDriver.driver"
VERSION="${VERSION:-1.0}"
PKG="$OUT/Soundboard-$VERSION.pkg"

# Installer signing identity. Defaults to a prefix match against the single
# Developer ID Installer cert in the keychain; override per the usage note above
# when ambiguous. (The bundles are signed by Xcode at build time, driven by the
# Developer ID Application identity / DEVELOPMENT_TEAM in each project.yml.)
INSTALLER_SIGN_ID="${INSTALLER_SIGN_ID:-Developer ID Installer}"

rm -rf "$BUILD" "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/Audio/Plug-Ins/HAL" "$OUT"

echo "==> generating Xcode projects"
( cd "$ROOT" && make generate >/dev/null )

echo "==> building app (Release, optimized — Xcode signs app + embedded frameworks)"
xcodebuild -workspace "$ROOT/Soundboard.xcworkspace" -scheme SoundboardApp \
    -configuration Release -derivedDataPath "$BUILD" \
    -destination "platform=macOS,arch=arm64" \
    ONLY_ACTIVE_ARCH=YES build >/dev/null

echo "==> building driver (Release — Xcode signs it with Developer ID Application)"
xcodebuild -project "$ROOT/LoopbackDriver/LoopbackDriver.xcodeproj" -scheme SoundboardDriver \
    -configuration Release -derivedDataPath "$BUILD" \
    -destination "platform=macOS,arch=arm64" \
    ONLY_ACTIVE_ARCH=YES build >/dev/null

APP_BUILT="$BUILD/Build/Products/Release/$APP"
DRIVER_BUILT="$BUILD/Build/Products/Release/$DRIVER"
[[ -d "$APP_BUILT" ]]    || { echo "app not found:    $APP_BUILT"; exit 1; }
[[ -d "$DRIVER_BUILT" ]] || { echo "driver not found: $DRIVER_BUILT"; exit 1; }

# The app (with its embedded frameworks, signed via Code Sign On Copy) and the
# driver were already signed by Xcode during the Release build above — hardened
# runtime, secure timestamp, and the app's entitlements all come from the
# project. Verify before staging so a signing misconfiguration fails loudly here
# rather than at notarization.
echo "==> verifying Xcode signatures"
codesign --verify --strict --verbose=2 "$APP_BUILT"
codesign --verify --strict --verbose=2 "$DRIVER_BUILT"

echo "==> staging payload"
cp -R "$APP_BUILT"    "$STAGE/Applications/"
cp -R "$DRIVER_BUILT" "$STAGE/Library/Audio/Plug-Ins/HAL/"

echo "==> building + signing $PKG with '$INSTALLER_SIGN_ID'"
chmod +x "$ROOT/installer/scripts/postinstall"
pkgbuild \
    --root "$STAGE" \
    --identifier ca.borisvanin.soundboard.pkg \
    --version "$VERSION" \
    --scripts "$ROOT/installer/scripts" \
    --install-location / \
    --ownership recommended \
    --sign "$INSTALLER_SIGN_ID" \
    "$PKG"

echo
echo "✅ built $PKG"
echo "   Install:   sudo installer -pkg \"$PKG\" -target /"
echo "   or double-click it in Finder (it will prompt for your password)."

# ---------------------------------------------------------------------------
# NOTARIZATION (to distribute to OTHER Macs) — the build above already signs the
# bundles with Developer ID Application and the .pkg with Developer ID Installer.
# To clear Gatekeeper on other Macs, notarize + staple the finished .pkg:
#   xcrun notarytool submit "$PKG" --apple-id you@id --team-id TEAMID \
#     --password APP_SPECIFIC_PW --wait
#   xcrun stapler staple "$PKG"
# ---------------------------------------------------------------------------
