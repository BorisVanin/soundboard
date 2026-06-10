#!/bin/bash
#
# Build, sign, install, and (re)load the Soundboard AudioServerPlugIn.
#
# coreaudiod loads HAL plugins only from /Library/Audio/Plug-Ins/HAL, validates
# their signature, and keeps the old copy in memory until restarted — so every
# install must copy (not symlink), fix ownership, sign, and kickstart the daemon.
#
# Usage:
#   ./install.sh            build (Release) + install + reload
#   ./install.sh debug      build (Debug, verbose logging) + install + reload
#   ./install.sh uninstall  remove the driver + reload
#
set -euo pipefail

DRIVER_NAME="SoundboardDriver.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Release is the default: optimized + per-access logging compiled out. The Debug
# build logs on every property poll, which serialises the plugin and makes
# loopback volume changes crawl. `./install.sh debug` opts back into verbose.
CONFIG="Release"
EXTRA_FLAGS=()
if [[ "${1:-}" == "debug" ]]; then
    CONFIG="Debug"
    EXTRA_FLAGS=(GCC_PREPROCESSOR_DEFINITIONS='$(inherited) SOUNDBOARD_VERBOSE=1')
fi

reload_coreaudio() {
    # coreaudiod is SIP-protected: `launchctl kickstart -k` is refused while SIP
    # is engaged ("Operation not permitted"). Killing it is allowed — launchd
    # relaunches it automatically.
    echo "==> restarting coreaudiod"
    sudo killall coreaudiod 2>/dev/null || true
}

if [[ "${1:-}" == "uninstall" ]]; then
    echo "==> removing $HAL_DIR/$DRIVER_NAME"
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME"
    reload_coreaudio
    echo "Done."
    exit 0
fi

echo "==> building $DRIVER_NAME ($CONFIG)"
if [[ ${#EXTRA_FLAGS[@]} -gt 0 ]]; then
    xcodebuild \
        -project "$PROJECT_DIR/LoopbackDriver.xcodeproj" \
        -scheme SoundboardDriver \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$PROJECT_DIR/.build" \
        "${EXTRA_FLAGS[@]}" \
        build CODE_SIGNING_ALLOWED=NO >/dev/null
else
    xcodebuild \
        -project "$PROJECT_DIR/LoopbackDriver.xcodeproj" \
        -scheme SoundboardDriver \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$PROJECT_DIR/.build" \
        build CODE_SIGNING_ALLOWED=NO >/dev/null
fi

BUILT="$PROJECT_DIR/.build/Build/Products/$CONFIG/$DRIVER_NAME"
[[ -d "$BUILT" ]] || { echo "build product not found at $BUILT"; exit 1; }

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$BUILT"

echo "==> installing to $HAL_DIR"
sudo rm -rf "$HAL_DIR/$DRIVER_NAME"
sudo cp -R "$BUILT" "$HAL_DIR/"
sudo chown -R root:wheel "$HAL_DIR/$DRIVER_NAME"
sudo chmod -R 755 "$HAL_DIR/$DRIVER_NAME"

reload_coreaudio

echo "==> verifying"
sleep 1
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Soundboard"; then
    echo "✅ Soundboard Output is registered."
else
    echo "⚠️  Not visible yet. Check Console.app (filter: coreaudiod) for signature/permission errors."
fi
