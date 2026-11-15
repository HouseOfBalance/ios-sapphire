# sensord Makefile
# Usage: make [OUTDIR=../obj] [SDK=/path/to/iPhoneOS16.5.sdk]

OUTDIR ?= ../obj
SDK ?= $(HOME)/sdks/theos-sdks/iPhoneOS16.5.sdk
LDID ?= $(HOME)/tools-dl/ldid/ldid
CC = /usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld -O2 -Wall -Wextra

all: $(OUTDIR)/sensord

$(OUTDIR)/sensord: sensord.c sns_wire.h
	@mkdir -p $(OUTDIR)
	$(CC) -o $@ $<
	$(LDID) -S $@
	@echo "Built: $@"

clean:
	rm -f $(OUTDIR)/sensord

install: $(OUTDIR)/sensord
	cp $(OUTDIR)/sensord /redwood/bin/sensord
	cp com.sapphire.sensord.plist /redwood/launchd/
	chmod 755 /redwood/bin/sensord
	chmod 644 /redwood/launchd/com.sapphire.sensord.plist

.PHONY: all clean install