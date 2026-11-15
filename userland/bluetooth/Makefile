# btmonitor Makefile
# Usage: make [OUTDIR=../obj] [SDK=/path/to/iPhoneOS16.5.sdk]

OUTDIR ?= ../obj
SDK ?= $(HOME)/sdks/theos-sdks/iPhoneOS16.5.sdk
LDID ?= $(HOME)/tools-dl/ldid/ldid
CC = /usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld -O2 -Wall -Wextra

all: $(OUTDIR)/btmonitor

$(OUTDIR)/btmonitor: btmonitor.c
	@mkdir -p $(OUTDIR)
	$(CC) -o $@ $<
	$(LDID) -S $@
	@echo "Built: $@"

clean:
	rm -f $(OUTDIR)/btmonitor

install: $(OUTDIR)/btmonitor
	cp $(OUTDIR)/btmonitor /redwood/bin/btmonitor
	chmod 755 /redwood/bin/btmonitor
	cp com.sapphire.btmonitor.plist /redwood/launchd/
	chmod 644 /redwood/launchd/com.sapphire.btmonitor.plist
	# Also copy to tweaks staging for installer
	mkdir -p /redwood/tweaks
	cp $(OUTDIR)/btmonitor /redwood/tweaks/btmonitor
	cp com.sapphire.btmonitor.plist /redwood/tweaks/

.PHONY: all clean install