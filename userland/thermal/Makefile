# thermald Makefile
# Usage: make [OUTDIR=../obj] [SDK=/path/to/iPhoneOS16.5.sdk]

OUTDIR ?= ../obj
SDK ?= $(HOME)/sdks/theos-sdks/iPhoneOS16.5.sdk
LDID ?= $(HOME)/tools-dl/ldid/ldid
CC = /usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $(SDK) -fuse-ld=lld -O2 -Wall -Wextra

all: $(OUTDIR)/thermald

$(OUTDIR)/thermald: thermald.c
	@mkdir -p $(OUTDIR)
	$(CC) -o $@ $<
	$(LDID) -S $@
	@echo "Built: $@"

clean:
	rm -f $(OUTDIR)/thermald

install: $(OUTDIR)/thermald
	cp $(OUTDIR)/thermald /redwood/bin/thermald
	cp com.sapphire.thermald.plist /redwood/launchd/
	chmod 755 /redwood/bin/thermald
	chmod 644 /redwood/launchd/com.sapphire.thermald.plist

.PHONY: all clean install