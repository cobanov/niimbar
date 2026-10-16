# NiimBar — derle, paketle, kur
#
#   make            derle
#   make bundle     build/NiimBar.app (imzasiz, yerel kullanim)
#   make install    /Applications'a kur ve baslat
#   make test       testler
#   make panel      paneli ornek veriyle build/panel.png olarak ciz
#   make release    imzala, noterlet, DMG'yi uret (yayina hazir)
#   make publish    GitHub Release + Homebrew cask (cobanov/tap)

VERSION     := 0.1.0
APP         := NiimBar
BUNDLE_ID   := dev.cobanov.niimbar
MIN_MACOS   := 14.0

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP).app
CONTENTS    := $(APP_BUNDLE)/Contents
BINARY      := .build/release/$(APP)
ICONSET     := $(BUILD_DIR)/$(APP).iconset
ICNS        := $(BUILD_DIR)/$(APP).icns
ZIP         := $(BUILD_DIR)/$(APP)-notarize.zip
DMG         := $(BUILD_DIR)/$(APP)-$(VERSION).dmg

# Imza: Developer ID, GHBar ile ayni keychain. Sifresi ~/.cobanov-signing/.kcpass.
SIGN_ID       := Developer ID Application: AHMET MERT COBANOGLU (6U58AKY6F8)
SIGN_KEYCHAIN := $(HOME)/Library/Keychains/cobanov-signing.keychain-db
# Noter: App Store Connect API anahtari (Obsidian helva.md'de kayitli).
NOTARY_KEY_ID ?= RQ96AFW6H2
NOTARY_ISSUER ?= 93179d25-e1b9-4256-941e-27126dcc7ea6
NOTARY_AUTH   := --key "$(HOME)/.appstoreconnect/private_keys/AuthKey_$(NOTARY_KEY_ID).p8" \
                 --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)"

.PHONY: all build test icon bundle install panel unlock sign notarize dmg release publish tap clean

all: build

build:
	swift build -c release

test:
	swift test

panel: build
	@mkdir -p $(BUILD_DIR)
	$(BINARY) --render-panel $(BUILD_DIR)/panel.png

icon: $(ICNS)

$(ICNS): Tools/makeicon.swift
	@mkdir -p $(BUILD_DIR)
	swift Tools/makeicon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

bundle: build $(ICNS)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY) $(CONTENTS)/MacOS/$(APP)
	cp $(ICNS) $(CONTENTS)/Resources/$(APP).icns
	@printf '%s' 'APPL????' > $(CONTENTS)/PkgInfo
	@/usr/libexec/PlistBuddy -c "Clear dict" \
	  -c "Add :CFBundleName string $(APP)" \
	  -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
	  -c "Add :CFBundleExecutable string $(APP)" \
	  -c "Add :CFBundleIconFile string $(APP)" \
	  -c "Add :CFBundlePackageType string APPL" \
	  -c "Add :CFBundleShortVersionString string $(VERSION)" \
	  -c "Add :CFBundleVersion string $(VERSION)" \
	  -c "Add :LSMinimumSystemVersion string $(MIN_MACOS)" \
	  -c "Add :LSUIElement bool true" \
	  $(CONTENTS)/Info.plist >/dev/null
	@# Ad-hoc imza: bildirimler ve girişte başlatma imzali paket istiyor.
	codesign --force --sign - $(APP_BUNDLE)
	@echo "paketlendi: $(APP_BUNDLE)"

# --- Yayin --------------------------------------------------------------
# Uygulama noterlenip staple edilir, sonra DMG'ye konur; DMG de ayrica
# imzalanip noterlenir. Boylece hem DMG hem icindeki uygulama cevrimdisi
# dogrulanir.

unlock:
	@security unlock-keychain -p "$$(cat $(HOME)/.cobanov-signing/.kcpass)" "$(SIGN_KEYCHAIN)"

sign: bundle unlock
	codesign --force --options runtime --timestamp --keychain "$(SIGN_KEYCHAIN)" \
	  --sign "$(SIGN_ID)" $(APP_BUNDLE)
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

notarize: sign
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP_BUNDLE) $(ZIP)
	xcrun notarytool submit $(ZIP) $(NOTARY_AUTH) --wait
	xcrun stapler staple $(APP_BUNDLE)
	@rm -f $(ZIP)
	spctl --assess --type execute --verbose=4 $(APP_BUNDLE)

dmg: notarize
	@rm -rf $(BUILD_DIR)/dmg $(DMG)
	@mkdir -p $(BUILD_DIR)/dmg
	ditto $(APP_BUNDLE) $(BUILD_DIR)/dmg/$(APP).app
	ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname "$(APP)" -srcfolder $(BUILD_DIR)/dmg -fs HFS+ -format UDZO -ov $(DMG)
	@rm -rf $(BUILD_DIR)/dmg
	codesign --force --timestamp --keychain "$(SIGN_KEYCHAIN)" --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) $(NOTARY_AUTH) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature --verbose=4 $(DMG)
	@shasum -a 256 $(DMG)

release: test dmg
	@echo "yayina hazir: $(DMG) — sonraki adim: make publish"

publish:
	@test -f $(DMG) || { echo "$(DMG) yok — once 'make release'"; exit 1; }
	gh release create v$(VERSION) $(DMG) --title "NiimBar $(VERSION)" \
	  --notes-file docs/release-notes/v$(VERSION).md --repo cobanov/niimbar
	$(MAKE) tap

# Cask'i tap reposuna gh api ile tek dosya olarak yazar (GHBar ile ayni yol).
tap:
	@SHA=$$(shasum -a 256 $(DMG) | cut -d' ' -f1); \
	sed -e "s/{{VERSION}}/$(VERSION)/g" -e "s/{{SHA256}}/$$SHA/g" Packaging/niimbar.rb.template > $(BUILD_DIR)/niimbar.rb; \
	B64=$$(base64 -i $(BUILD_DIR)/niimbar.rb); \
	EXISTING=$$(gh api repos/cobanov/homebrew-tap/contents/Casks/niimbar.rb --jq .sha 2>/dev/null || true); \
	gh api -X PUT repos/cobanov/homebrew-tap/contents/Casks/niimbar.rb -f message="niimbar $(VERSION)" \
	  -f content="$$B64" $${EXISTING:+-f sha=$$EXISTING} > /dev/null; \
	echo "tap guncellendi: brew install --cask cobanov/tap/niimbar"

# --- Kurulum ------------------------------------------------------------

install: bundle
	@pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(APP_BUNDLE) /Applications/
	open /Applications/$(APP).app

clean:
	rm -rf .build $(BUILD_DIR)
