# SapphireTools v2 — build bang clang + iOS SDK (Linux/macOS), ky bang ldid.
#
#   make                         build ra build/SapphireTools.app
#   make install DESTDIR=/path   chep vao <DESTDIR>/Applications (staging rootfs), chmod 6755 binary
#   make deploy DEVICE=root@IP   scp len may + chown/chmod + uicache qua SSH
#   make clean
#
# Bien co the ghi de:
#   SDK=/duong/dan/iPhoneOS16.x.sdk   (bat buoc tren Linux; tren macOS tu dong qua xcrun)
#   CLANG=clang                       (vi du: CLANG=/opt/llvm/bin/clang)
#   EXTRA_CFLAGS / EXTRA_LDFLAGS      (vi du: EXTRA_LDFLAGS=-fuse-ld=/opt/cctools/bin/arm64-apple-darwin-ld)
#   LDID=ldid
#   FULL_ROOT=1                       (them -DSW_FULL_ROOT: setuid(0) day du, xem main())

APP_NAME    := SapphireTools
BUILD_DIR   := build
APP_DIR     := $(BUILD_DIR)/$(APP_NAME).app
BIN         := $(APP_DIR)/$(APP_NAME)

CLANG       ?= clang
LDID        ?= ldid
SDK         ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
TARGET      ?= arm64-apple-ios16.0
DESTDIR     ?=
DEVICE      ?= root@192.168.1.100

CFLAGS      := -target $(TARGET) -isysroot $(SDK) -fobjc-arc -O2 \
	           -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations $(EXTRA_CFLAGS)
LDFLAGS     := -framework UIKit -framework Foundation -framework QuartzCore -Wl,-dead_strip $(EXTRA_LDFLAGS)

ifdef FULL_ROOT
CFLAGS += -DSW_FULL_ROOT=1
endif

.PHONY: all check-sdk icons install deploy clean

all: $(BIN)

check-sdk:
	@test -n "$(SDK)" || { echo "error: iOS SDK not found. Run: make SDK=/path/to/iPhoneOS.sdk"; exit 1; }
	@test -d "$(SDK)" || { echo "error: SDK path '$(SDK)' does not exist"; exit 1; }

icons:
	python3 tools/make_icon.py

$(BIN): main.m Info.plist entitlements.plist $(wildcard icons/AppIcon60x60*.png) | check-sdk
	@mkdir -p $(APP_DIR)
	$(CLANG) $(CFLAGS) main.m -o $(BIN) $(LDFLAGS)
	cp Info.plist $(APP_DIR)/Info.plist
	cp icons/AppIcon60x60@2x.png icons/AppIcon60x60@3x.png $(APP_DIR)/
	printf 'APPL????' > $(APP_DIR)/PkgInfo
	$(LDID) -Sentitlements.plist $(BIN)
	@echo "Built $(APP_DIR)"

install: all
	mkdir -p $(DESTDIR)/Applications
	rm -rf $(DESTDIR)/Applications/$(APP_NAME).app
	cp -R $(APP_DIR) $(DESTDIR)/Applications/
	-chown -R 0:0 $(DESTDIR)/Applications/$(APP_NAME).app
	chmod 6755 $(DESTDIR)/Applications/$(APP_NAME).app/$(APP_NAME)
	@echo "Installed to $(DESTDIR)/Applications/$(APP_NAME).app"

deploy: all
	ssh $(DEVICE) 'rm -rf /Applications/$(APP_NAME).app'
	scp -r $(APP_DIR) $(DEVICE):/Applications/
	ssh $(DEVICE) 'chown -R 0:0 /Applications/$(APP_NAME).app && chmod 6755 /Applications/$(APP_NAME).app/$(APP_NAME) && (uicache -p /Applications/$(APP_NAME).app || uicache -a)'

clean:
	rm -rf $(BUILD_DIR)
