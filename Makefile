# Soundboard — multi-module build.
#
# Every module is a standalone XcodeGen project. Frameworks are generated
# before the consumers that reference them (projectReferences need the
# referenced .xcodeproj to exist on disk at generation time).

MODULES_LIB   = MixerModel MixerEngine MIDISurface DriverControl
MODULES_APP   = LoopbackDriver SoundboardApp
MODULES       = $(MODULES_LIB) $(MODULES_APP)
WORKSPACE     = Soundboard.xcworkspace

all: mint_bootstrap generate generate_workspace

mint_bootstrap:
	MINT_LINK_PATH=.bin mint bootstrap --link

# Every project.yml resolves DEVELOPMENT_TEAM from the environment at generation
# time (XcodeGen ${VAR} substitution). Refuse to generate with an empty team so
# we never emit projects with a broken/blank signing identity — set your Apple
# Developer Team ID first, e.g. `export DEVELOPMENT_TEAM=ABCDE12345`.
require_team:
	@if [ -z "$$DEVELOPMENT_TEAM" ]; then \
		echo "error: DEVELOPMENT_TEAM is not set."; \
		echo "       Set your Apple Developer Team ID before generating, e.g.:"; \
		echo "         export DEVELOPMENT_TEAM=ABCDE12345"; \
		echo "       (Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Team ID.)"; \
		exit 1; \
	fi

# Order matters: model first, then taps/engine/midi, then driver + app.
generate: require_team
	@for m in $(MODULES); do \
		echo "==> xcodegen $$m"; \
		( cd $$m && MINT_LINK_PATH=../.bin mint run xcodegen ) || exit 1; \
	done

# The workspace stitches the per-module projects together. XcodeGen here only
# emits per-module projects, so we generate the workspace ourselves from MODULES.
generate_workspace:
	@mkdir -p "$(WORKSPACE)"
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Workspace version = "1.0">' > "$(WORKSPACE)/contents.xcworkspacedata"
	@for m in $(MODULES); do \
		printf '   <FileRef location = "group:%s/%s.xcodeproj"></FileRef>\n' "$$m" "$$m" >> "$(WORKSPACE)/contents.xcworkspacedata"; \
	done
	@printf '%s\n' '</Workspace>' >> "$(WORKSPACE)/contents.xcworkspacedata"
	@echo "==> wrote $(WORKSPACE)"

clean:
	@for m in $(MODULES); do \
		rm -rf "$$m/$$m.xcodeproj"; \
	done
	@rm -rf "$(WORKSPACE)"

open:
	open "$(WORKSPACE)"

scratch: clean all open

# Driver install lifecycle (copies into /Library/Audio/Plug-Ins/HAL, signs,
# fixes ownership, restarts coreaudiod). Prompts for sudo.
install-driver:
	cd LoopbackDriver && ./install.sh

uninstall-driver:
	cd LoopbackDriver && ./install.sh uninstall

reload-coreaudio:
	sudo killall coreaudiod

# Build a double-clickable .pkg (app → /Applications, driver → HAL, restarts
# coreaudiod). Local/ad-hoc signed; override the version with PKG_VERSION=x.y.
PKG_VERSION ?= 1.0
installer: chmod_installer
	VERSION=$(PKG_VERSION) installer/build-pkg.sh

chmod_installer:
	@chmod +x installer/build-pkg.sh installer/scripts/postinstall

.PHONY: all mint_bootstrap require_team generate generate_workspace clean open scratch \
        install-driver uninstall-driver reload-coreaudio installer chmod_installer \
        test tools

# Unit tests for the driver's shared-memory ring + protocol (RingOwner/RingClient).
# Pure in-process logic + real POSIX shm — no coreaudiod, no HAL, no install.
test:
	./tests/run.sh

# Build the dev CLI tools (soundboardctl, tap_feed, make_icon) into dist/.
tools:
	$(MAKE) -C tools
