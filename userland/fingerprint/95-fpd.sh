#!/bin/bash
# 95-fpd.sh: Start fingerprint daemon (fpd) at boot
# Runs from /redwood/boot.d/ (userland, after rootfs mounted RW)
# Avoids system launchd cache (/System/Library/xpc/launchd.plist) which requires Apple platform binaries

echo "[95-fpd] Starting fingerprint daemon..."

FPD_BIN="/redwood/bin/fpd"
FPD_SOCK="/var/run/fpd.sock"
FPD_LOG="/var/tmp/fpd.log"

# Ensure fpd binary exists
if [ ! -x "$FPD_BIN" ]; then
    echo "[95-fpd] ERROR: $FPD_BIN not found or not executable"
    exit 1
fi

# Clean up stale socket
rm -f "$FPD_SOCK"

# Start fpd in background (detached, with logging)
# fpd daemonizes itself; we just launch it
nohup "$FPD_BIN" >>"$FPD_LOG" 2>&1 &

# Give it a moment to create the socket
for i in 1 2 3 4 5; do
    if [ -S "$FPD_SOCK" ]; then
        echo "[95-fpd] fpd started successfully (socket: $FPD_SOCK)"
        exit 0
    fi
    sleep 0.2
done

echo "[95-fpd] WARNING: fpd socket not created after 1s (may still be initializing)"
exit 0
