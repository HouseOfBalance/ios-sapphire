# RedwoodAudio.driver Makefile
# Usage: make [OUTDIR=../obj] [SDK=/path/to/iPhoneOS16.5.sdk]

OUTDIR ?= ../obj
SDK ?= $(HOME)/sdks/theos-sdks/iPhoneOS16.5.sdk
LDID ?= $(HOME)/tools-dl/ldid/ldid
CC = /usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld -O2 -Wall

all: $(OUTDIR)/RedwoodAudio.driver/RedwoodAudio

$(OUTDIR)/RedwoodAudio.driver/RedwoodAudio: audio_plugin.c audio_plugin.plist
	@mkdir -p $(OUTDIR)/RedwoodAudio.driver
	$(CC) -bundle -framework CoreFoundation -o $(OUTDIR)/RedwoodAudio.driver/RedwoodAudio audio_plugin.c
	$(LDID) -S $(OUTDIR)/RedwoodAudio.driver/RedwoodAudio
	cp audio_plugin.plist $(OUTDIR)/RedwoodAudio.driver/Info.plist
	@echo "Built: $(OUTDIR)/RedwoodAudio.driver"

clean:
	rm -rf $(OUTDIR)/RedwoodAudio.driver

install: $(OUTDIR)/RedwoodAudio.driver/RedwoodAudio
	cp -R $(OUTDIR)/RedwoodAudio.driver /System/Library/Audio/Plug-Ins/HAL/
	chown -R 0:0 /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver
	chmod -R 755 /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver
	chmod 644 /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/Info.plist

.PHONY: all clean install