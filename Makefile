# Soundboard — multi-module build.
#
# Every module is a standalone XcodeGen project. Frameworks are generated
# before the consumers that reference them (projectReferences need the
# referenced .xcodeproj to exist on disk at generation time).

MODULES_LIB   = MixerModel MixerEngine MIDISurface DriverControl
MODULES_APP   = LoopbackDriver SoundboardApp
MODULES       = $(MODULES_LIB) $(MODULES_APP)
WORKSPACE     = Soundboard.xcworkspace

# Bundle-ID prefix shared by every module: each project.yml resolves
# ${BUNDLE_IDENTIFIER} from the environment at generation time (XcodeGen
# substitution) and appends its own suffix (e.g. ${BUNDLE_IDENTIFIER}.engine).
# Defaults to the project's id but is overridable (fork / different account):
#   make BUNDLE_IDENTIFIER=com.acme.soundboard   (or export it)
BUNDLE_IDENTIFIER ?= ca.borisvanin.soundboard
export BUNDLE_IDENTIFIER

all: mint_bootstrap generate generate_workspace

mint_bootstrap:
	MINT_LINK_PATH=.bin mint bootstrap --link

# Order matters: model first, then taps/engine/midi, then driver + app.
generate:
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

# Build a double-clickable .pkg into dist/ (app → /Applications, driver → HAL,
# restarts coreaudiod). Signed with Developer ID Application (app + driver) and
# Developer ID Installer (.pkg). Override the version with PKG_VERSION=x.y.
PKG_VERSION ?= 1.0
installer: chmod_installer
	VERSION=$(PKG_VERSION) installer/build-pkg.sh

chmod_installer:
	@chmod +x installer/build-pkg.sh installer/scripts/postinstall

.PHONY: all mint_bootstrap generate generate_workspace clean open scratch \
        install-driver uninstall-driver reload-coreaudio installer chmod_installer \
        test tools

# Unit tests for the driver's shared-memory ring + protocol (RingOwner/RingClient).
# Pure in-process logic + real POSIX shm — no coreaudiod, no HAL, no install.
test:
	./tests/run.sh

# Build the dev CLI tools (soundboardctl, tap_feed, make_icon) into dist/.
tools:
	$(MAKE) -C tools
