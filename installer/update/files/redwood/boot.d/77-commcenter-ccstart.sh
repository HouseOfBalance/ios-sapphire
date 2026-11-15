#!/bin/bash
# 77-commcenter-ccstart.sh: Ensure CommCenter is running via ccstart wrapper
# This runs at boot to reload CommCenter launchd job if needed

# Wait for launchd to be ready
for i in $(seq 1 10); do
    launchctl list >/dev/null 2>&1 && break
    sleep 1
done

# Reload CommCenter job to pick up ccstart wrapper
launchctl list com.apple.CommCenter >/dev/null 2>&1 && launchctl unload /System/Library/LaunchDaemons/com.apple.CommCenter.plist 2>/dev/null
launchctl load /System/Library/LaunchDaemons/com.apple.CommCenter.plist 2>/dev/null || true

# Also ensure autodata starts (qmitool autodata)
if [ -x /redwood/bin/qmitool ] && [ ! -f /var/tmp/autodata.off ]; then
    /redwood/bin/qmitool autodata &
fi

exit 0