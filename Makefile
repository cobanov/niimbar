# NiimBar — derle, paketle, kur
#
#   make            derle
#   make bundle     build/NiimBar.app (imzasiz, yerel kullanim)
#   make install    /Applications'a kur ve baslat
#   make test       testler
#   make panel      paneli ornek veriyle build/panel.png olarak ciz

VERSION     := 0.1.0
APP         := NiimBar
BUNDLE_ID   := dev.cobanov.niimbar
MIN_MACOS   := 14.0

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP).app
CONTENTS    := $(APP_BUNDLE)/Contents
BINARY      := .build/release/$(APP)

.PHONY: all build test bundle install panel clean

all: build

build:
	swift build -c release

test:
	swift test

panel: build
	@mkdir -p $(BUILD_DIR)
	$(BINARY) --render-panel $(BUILD_DIR)/panel.png

bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/$(APP)
	@printf '%s' 'APPL????' > $(CONTENTS)/PkgInfo
	@/usr/libexec/PlistBuddy -c "Clear dict" \
	  -c "Add :CFBundleName string $(APP)" \
	  -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
	  -c "Add :CFBundleExecutable string $(APP)" \
	  -c "Add :CFBundlePackageType string APPL" \
	  -c "Add :CFBundleShortVersionString string $(VERSION)" \
	  -c "Add :CFBundleVersion string $(VERSION)" \
	  -c "Add :LSMinimumSystemVersion string $(MIN_MACOS)" \
	  -c "Add :LSUIElement bool true" \
	  $(CONTENTS)/Info.plist >/dev/null
	@# Ad-hoc imza: bildirimler ve girişte başlatma imzali paket istiyor.
	codesign --force --sign - $(APP_BUNDLE)
	@echo "paketlendi: $(APP_BUNDLE)"

install: bundle
	@pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(APP_BUNDLE) /Applications/
	open /Applications/$(APP).app

clean:
	rm -rf .build $(BUILD_DIR)
