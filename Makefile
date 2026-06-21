# Soundboard — developer tasks.
#
# Built on xcodegen-templates (vendored at ./xcodegen-templates via `mise run
# templates`). Every module is a standalone XcodeGen project whose project.yml
# `include:`s the templates by env-var path (${TEMPLATES_HOME}/…), so
# PROJECT_HOME / TEMPLATES_HOME / DEVELOPMENT_TEAM must be in the environment
# (loaded from .envrc via direnv — see .envrc.default). Toolchain (xcodegen,
# swiftlint) is pinned in mise.toml and invoked via `mise exec`.
#
# Distribution (pkg / dmg / dist) reuses the templates' shared scripts under
# xcodegen-templates/scripts — see docs in xcodegen-templates/docs/DISTRIBUTION.md.

# Frameworks are generated before the consumers that reference them
# (projectReferences need the referenced .xcodeproj on disk at generation time):
# model first, then engine/midi/driver-control, then the HAL driver + the app.
MODULES_LIB   = MixerModel MixerEngine MIDISurface DriverControl
MODULES_APP   = LoopbackDriver SoundboardApp LatencyMeter
MODULES       = $(MODULES_LIB) $(MODULES_APP)
WORKSPACE     = Soundboard.xcworkspace
SCHEME        = Soundboard
DESTINATION   = platform=macOS

# Bundle-ID prefix shared by every module: each project.yml resolves
# ${PROJECT_IDENTIFIER} from the environment at generation time and appends its
# own suffix (e.g. ${PROJECT_IDENTIFIER}.engine). Defaults to the project's id but
# is overridable (fork / different account):
#   make PROJECT_IDENTIFIER=com.acme.soundboard   (or export it via .envrc)
PROJECT_IDENTIFIER ?= ca.borisvanin.soundboard
export PROJECT_IDENTIFIER

# ── Distribution wiring (consumed by xcodegen-templates/scripts) ─────────────
# The shared scripts read project specifics from the environment; machine
# identity / notary creds come from .envrc. The scheme is "Soundboard" so the
# built bundle is Soundboard.app and artifacts are named Soundboard-<version>.
# PKG_SCRIPTS_DIR points the .pkg at our postinstall (installs the embedded HAL
# driver into /Library/Audio/Plug-Ins/HAL + restarts coreaudiod).
SCRIPTS := $(abspath xcodegen-templates/scripts)
export APP_PROJECT     := $(abspath SoundboardApp/SoundboardApp.xcodeproj)
export APP_SCHEME      := $(SCHEME)
export PKG_IDENTIFIER  := $(PROJECT_IDENTIFIER).pkg
export PKG_SCRIPTS_DIR := $(abspath pkg-scripts)

.PHONY: all gen generate_workspace debug release open clean scratch \
        pkg dmg dist test tools latency

all: gen

# ── Generate ─────────────────────────────────────────────────────────────────
# Regenerate every module's .xcodeproj (in dependency order) and the workspace
# that stitches them together. The generated projects are disposable + git-ignored.
gen: generate_workspace

generate_workspace:
	@for m in $(MODULES); do \
		echo "==> xcodegen $$m"; \
		( cd $$m && mise exec -- xcodegen generate ) || exit 1; \
	done
	@mkdir -p "$(WORKSPACE)"
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Workspace version = "1.0">' > "$(WORKSPACE)/contents.xcworkspacedata"
	@for m in $(MODULES); do \
		printf '   <FileRef location = "group:%s/%s.xcodeproj"></FileRef>\n' "$$m" "$$m" >> "$(WORKSPACE)/contents.xcworkspacedata"; \
	done
	@printf '%s\n' '</Workspace>' >> "$(WORKSPACE)/contents.xcworkspacedata"
	@echo "==> wrote $(WORKSPACE)"

# ── Build ────────────────────────────────────────────────────────────────────
debug: gen
	xcodebuild -project $(APP_PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DESTINATION)' build

release: gen
	xcodebuild -project $(APP_PROJECT) -scheme $(SCHEME) \
		-configuration Release -destination '$(DESTINATION)' build

open: gen
	open "$(WORKSPACE)"

clean:
	@for m in $(MODULES); do rm -rf "$$m/$$m.xcodeproj"; done
	@rm -rf "$(WORKSPACE)"

scratch: clean all open

# ── Distribution (Developer ID, notarized) ───────────────────────────────────
# Each target regenerates the projects, builds a distribution-signed artifact via
# the shared scripts, and notarizes + staples it. The app's Developer ID export
# also re-signs the embedded HAL driver; the .pkg postinstall lays it into
# /Library/Audio/Plug-Ins/HAL on the target Mac. Needs DEVELOPMENT_TEAM +
# NOTARY_PROFILE in .envrc and Developer ID Application/Installer certs in your
# keychain. See xcodegen-templates/docs/DISTRIBUTION.md.

# Notarized .pkg installer (app → /Applications, driver → HAL via postinstall).
pkg: gen
	$(SCRIPTS)/notarize.sh "$$($(SCRIPTS)/build-pkg.sh)"

# Notarized .dmg disk image (drag the app to Applications; driver not installed).
dmg: gen
	$(SCRIPTS)/notarize.sh "$$($(SCRIPTS)/build-dmg.sh)"

# Both distribution artifacts.
dist: pkg dmg

# ── Project-specific dev tasks ───────────────────────────────────────────────
# Unit tests for the driver's shared-memory ring + protocol (RingOwner/RingClient).
# Pure in-process logic + real POSIX shm — no coreaudiod, no HAL, no install.
test:
	./tests/run.sh

# Build the dev CLI tools (soundboardctl, tap_feed, make_icon) into dist/.
tools:
	$(MAKE) -C tools

# Audio-latency measurement app. Builds LatencyMeter.app and measures the delay the
# Soundboard pipeline adds for a given OUTPUT device, via a {OUTPUT + Scarlett 2i2}
# multi-output and the Scarlett's hardware loopback. REQUIRES a Scarlett 2i2 + the
# app's Microphone permission (approve the TCC prompt on first run).
#
#   make latency OUTPUT="DELL S2721QS"            # measure for the DELL
#   make latency OUTPUT="DELL S2721QS" DURATION=4 # longer square
LM_DERIVED := LatencyMeter/build
DURATION   ?= 2
# Self-contained: regenerate only the LatencyMeter project and rebuild its binary
# every run (no full `gen` of all modules), then measure.
latency:
	@echo "==> xcodegen LatencyMeter"
	@( cd LatencyMeter && mise exec -- xcodegen generate )
	xcodebuild -project LatencyMeter/LatencyMeter.xcodeproj -scheme LatencyMeter \
		-configuration Debug -destination '$(DESTINATION)' \
		-derivedDataPath $(LM_DERIVED) build
	@APP="$(LM_DERIVED)/Build/Products/Debug/LatencyMeter.app/Contents/MacOS/LatencyMeter"; \
	if [ -z '$(OUTPUT)' ]; then echo "usage: make latency OUTPUT=\"<output device name>\" [DURATION=2]"; exit 2; fi; \
	mkdir -p dist/latency; \
	echo "==> $$APP \"$(OUTPUT)\" --duration $(DURATION)"; \
	"$$APP" "$(OUTPUT)" --out dist/latency/latency-$(DURATION)s.wav --duration $(DURATION)
