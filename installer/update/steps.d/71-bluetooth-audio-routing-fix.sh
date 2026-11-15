#!/bin/bash
# 71-bluetooth-audio-routing-fix.sh: Fix Bluetooth Audio (TWS) Output Routing
# Root cause: RedwoodAudio.driver (audio_plugin.c) only exposes 4 devices:
#   Speaker, Hawking, Actuator, Codec
# Missing: Bluetooth A2DP device that CoreAudio can route to when btshim connects.
#
# Fix: Add Bluetooth A2DP device to RedwoodAudio.driver (done in audio_plugin.c)
#      and run btmonitor daemon to watch btshim control socket for HCI events
#      and post route-change notifications via notify(3).

set -e

echo "=== [71] Fixing Bluetooth Audio Routing ==="

# 1. Install btmonitor binary (built from userland/bluetooth/btmonitor.c)
# The binary should be pre-built and placed in /redwood/tweaks/btmonitor by the build
if [ -f /redwood/tweaks/btmonitor ]; then
    cp /redwood/tweaks/btmonitor /redwood/bin/btmonitor
    chmod 755 /redwood/bin/btmonitor
    echo "  ✓ btmonitor binary installed to /redwood/bin/btmonitor"
else
    echo "  ⚠ WARNING: btmonitor binary not found at /redwood/tweaks/btmonitor"
    echo "    Build it first: cd userland/bluetooth && make OUTDIR=/redwood/tweaks"
fi

# 2. Install btmonitor launchd plist
if [ -f /redwood/tweaks/com.sapphire.btmonitor.plist ]; then
    cp /redwood/tweaks/com.sapphire.btmonitor.plist /redwood/launchd/
    chmod 644 /redwood/launchd/com.sapphire.btmonitor.plist
    echo "  ✓ btmonitor launchd plist installed"
else
    echo "  ⚠ WARNING: btmonitor plist not found"
fi

# 3. Create boot.d script to load it
cat > /redwood/boot.d/71-bluetooth-audio.sh <<'EOF'
#!/bin/bash
# Load Bluetooth audio route monitor (btmonitor)
launchctl list com.sapphire.btmonitor >/dev/null 2>&1 || launchctl load /redwood/launchd/com.sapphire.btmonitor.plist
EOF
chmod 755 /redwood/boot.d/71-bluetooth-audio.sh

# 4. Ensure btshim creates proper uart node for bluetoothd
# (already done in btshim.c:uart_node())

# 5. The audio_plugin.c already has Bluetooth A2DP device support:
#    - OBJECT_BLUETOOTH, OBJECT_BLUETOOTH_OUTPUT, OBJECT_BLUETOOTH_VOLUME
#    - Transport type 'btle'
#    - Volume control via OBJECT_BLUETOOTH_VOLUME
#    - Stream activation tracking via bluetooth_connected flag
#    - This requires rebuilding audio_plugin.c (patch already applied in source)

echo "=== [71] Bluetooth audio routing fix installed ==="
echo "  - btmonitor daemon will watch btshim control socket via kqueue"
echo "  - Posts com.sapphire.audio.route-change on ACL/A2DP events"
echo "  - RedwoodAudio.driver has Bluetooth A2DP device (OBJECT_BLUETOOTH*)"
echo "  - Requires: btmonitor binary in /redwood/bin/ (build from userland/bluetooth/)"
true