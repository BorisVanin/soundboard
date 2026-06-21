# Builds the Soundboard dev tools into the repo-root dist/ folder.
#
#   cd tools && make          # build all tools -> ../dist
#   cd tools && make clean
#
# (Driver ring/protocol UNIT TESTS live in ../tests — run with `make test`
#  from the repo root, or ../tests/run.sh.)

DIST       := ../dist
SWIFTC     := swiftc
SWIFTFLAGS := -O

TOOLS := $(DIST)/soundboardctl $(DIST)/tap_feed $(DIST)/make_icon

.PHONY: all clean
all: $(TOOLS)
	@echo "==> built: $(TOOLS)"

$(DIST):
	mkdir -p $(DIST)

# Control + log CLI (drive the running app, tail app/driver logs).
$(DIST)/soundboardctl: soundboardctl.swift | $(DIST)
	$(SWIFTC) $(SWIFTFLAGS) soundboardctl.swift -framework Foundation -framework CoreAudio -o $@

# System-audio process-tap reference (writes captured audio into a ring).
$(DIST)/tap_feed: tap_feed.swift RingAtomics.h | $(DIST)
	$(SWIFTC) $(SWIFTFLAGS) tap_feed.swift -import-objc-header RingAtomics.h \
		-framework CoreAudio -framework AudioToolbox -framework Foundation -o $@

# App-icon generator: dist/make_icon <output.appiconset-dir>
$(DIST)/make_icon: make_icon.swift | $(DIST)
	$(SWIFTC) $(SWIFTFLAGS) make_icon.swift -framework AppKit -o $@

clean:
	rm -f $(TOOLS)
