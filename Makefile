# SwiftDict Makefile
#
# Common targets:
#   make            -> debug build (binary only, logs to stdout + file)
#   make debug      -> same as `make`
#   make release    -> release build (binary only, logs to file only)
#   make app        -> build SwiftDict.app bundle in build/
#   make dmg        -> build DMG installer at dist/SwiftDict-<version>.dmg
#   make run        -> build debug + run the binary
#   make install    -> build .app, replace /Applications/SwiftDict.app, relaunch
#   make clean      -> remove all build artifacts

SWIFTC        := swiftc
TARGET        := SwiftDict
SOURCES       := main.swift BuildInfo.swift
LIBS          := -lsqlite3

# Derive build metadata
COMMIT        := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME    := $(shell date "+%Y-%m-%d %H:%M:%S %z")
VERSION       := $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")

# Paths
BUILD_DIR     := build
DIST_DIR      := dist
APP_NAME      := SwiftDict
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH      := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
VOL_NAME      := $(APP_NAME)

# Swift build flags
COMMON_FLAGS  := $(LIBS)
DEBUG_FLAGS   := -D DEBUG -g -Onone
RELEASE_FLAGS := -O

.PHONY: all debug release app dmg run clean install sign BuildInfo.swift

all: debug

# ----------------------------------------------------------------------------
# BuildInfo.swift (regenerated on every build so commit/time stay fresh)
# ----------------------------------------------------------------------------
BuildInfo.swift: BuildInfo.swift.in
	@echo "==> Generating BuildInfo.swift (commit=$(COMMIT), version=$(VERSION))"
	@sed -e 's|@COMMIT@|$(COMMIT)|g' \
	     -e 's|@BUILD_TIME@|$(BUILD_TIME)|g' \
	     -e 's|@VERSION@|$(VERSION)|g' \
	     BuildInfo.swift.in > BuildInfo.swift

# ----------------------------------------------------------------------------
# Binary targets
# ----------------------------------------------------------------------------
debug: BuildInfo.swift
	@echo "==> Building DEBUG binary"
	$(SWIFTC) -o $(TARGET) $(SOURCES) $(COMMON_FLAGS) $(DEBUG_FLAGS)

release: BuildInfo.swift
	@echo "==> Building RELEASE binary"
	$(SWIFTC) -o $(TARGET) $(SOURCES) $(COMMON_FLAGS) $(RELEASE_FLAGS)

run: debug
	./$(TARGET)

# ----------------------------------------------------------------------------
# .app bundle
# ----------------------------------------------------------------------------
app: release
	@echo "==> Building app bundle at $(APP_BUNDLE)"
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(TARGET) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@sed -e 's|@VERSION@|$(VERSION)|g' \
	     Resources/Info.plist.in > $(APP_BUNDLE)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then \
	    cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns; \
	    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
	        $(APP_BUNDLE)/Contents/Info.plist 2>/dev/null || true; \
	fi
	@$(MAKE) sign
	@echo "==> App bundle ready: $(APP_BUNDLE)"

# Ad-hoc code signing (no developer account required).
# Users will see a Gatekeeper warning on first launch; right-click -> Open.
sign:
	@echo "==> Ad-hoc signing $(APP_BUNDLE)"
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@codesign --verify --verbose=2 $(APP_BUNDLE) || true

# ----------------------------------------------------------------------------
# DMG installer
# ----------------------------------------------------------------------------
dmg: app
	@mkdir -p $(DIST_DIR)
	@./scripts/make-dmg.sh $(APP_BUNDLE) $(DMG_PATH) $(VOL_NAME)
	@echo "==> DMG ready: $(DMG_PATH)"

# ----------------------------------------------------------------------------
# Install to /Applications
# ----------------------------------------------------------------------------
install: app
	@echo "==> Installing to /Applications/$(APP_NAME).app"
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "/Applications/"
	@open "/Applications/$(APP_NAME).app"
	@echo "==> Installed and launched"

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
clean:
	@echo "==> Cleaning build artifacts"
	@rm -f $(TARGET) BuildInfo.swift
	@rm -rf $(BUILD_DIR) $(DIST_DIR)
