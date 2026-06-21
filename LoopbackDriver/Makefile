# LoopbackDriver — build & dev-install the AudioServerPlugIn.
#
#   make build     Release build into ./build
#   make install   build, then replace the live HAL plug-in and restart coreaudiod
#                  (requires sudo; coreaudiod must be able to load a signed driver —
#                  the Release config must carry your signing identity)
#   make clean     remove ./build

PROJECT   := LoopbackDriver.xcodeproj
SCHEME    := SoundboardDriver
CONFIG    := Release
BUILD_DIR := build
DRIVER    := SoundboardDriver.driver
HAL_DIR   := /Library/Audio/Plug-Ins/HAL
BUILT     := $(BUILD_DIR)/Build/Products/$(CONFIG)/$(DRIVER)

.PHONY: build install clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) build

install: build
	sudo rm -rf "$(HAL_DIR)/$(DRIVER)"
	sudo cp -R "$(BUILT)" "$(HAL_DIR)/$(DRIVER)"
	sudo killall coreaudiod || true
	@echo "Installed $(DRIVER) -> $(HAL_DIR); coreaudiod restarted."

clean:
	rm -rf $(BUILD_DIR)
