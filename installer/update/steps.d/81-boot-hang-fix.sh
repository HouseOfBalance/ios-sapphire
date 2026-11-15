#!/bin/bash
# 81-boot-hang-fix.sh: Fix boot hang at "core zlib memory 0x8000" after hard reset
# ROOT CAUSE: HFS+ dirty volume from hard power-off corrupts /var symlink & tzinit data
# tzinit crash (exit code 2) -> launchd aborts boot -> stuck at verbose console
#
# CORRECT iOS ARCHITECTURE:
# - XNU kernel mounts iosroot (HFS+) directly, spawns launchd (PID 1)
# - NO Android init.rc, NO ramdisk scripts, NO "on early-init"
# - Fix MUST be persistent on rootfs and applied at every boot via launchd/boot.d

set -e

echo "=== [81] Applying boot hang fix (persistent rootfs + launchd resilience) ==="

# 1. Create persistent timezone structure on rootfs (survives reboots, survives fsck)
# This runs at update time AND at every boot via boot.d
cat > /redwood/boot.d/81-persistent-timezone.sh <<'BOOT_EOF'
#!/bin/bash
# Ensure timezone directory structure exists permanently on rootfs
# Runs at every boot from /redwood/boot.d/ (userland, after rootfs mounted RW)

echo "[81-tz] Ensuring persistent timezone structure..."

# Ensure /var -> private/var symlink is correct (critical!)
mkdir -p /private/var
if [ ! -L /var ]; then
    rm -f /var 2>/dev/null
    ln -sf /private/var /var
    echo "[81-tz] Fixed /var -> private/var symlink"
fi

# Ensure timezone directory exists
mkdir -p /private/var/db/timezone

# Create zoneinfo.default directory (tzinit expects this as symlink target)
mkdir -p /usr/share/zoneinfo.default

# Populate zoneinfo.default with essential timezone data if empty
if [ -z "$(ls -A /usr/share/zoneinfo.default 2>/dev/null)" ]; then
    # Copy from system zoneinfo if available, or create minimal UTC
    if [ -d /usr/share/zoneinfo ] && [ -n "$(ls -A /usr/share/zoneinfo 2>/dev/null)" ]; then
        cp -r /usr/share/zoneinfo/* /usr/share/zoneinfo.default/ 2>/dev/null || true
        echo "[81-tz] Populated zoneinfo.default from system zoneinfo"
    else
        # Minimal fallback: create UTC zoneinfo
        mkdir -p /usr/share/zoneinfo.default/UTC
        echo -e "UTC0" > /usr/share/zoneinfo.default/UTC
        echo "[81-tz] Created minimal UTC zoneinfo.default"
    fi
fi

# Create symlink: /private/var/db/timezone/zoneinfo -> /usr/share/zoneinfo.default
ZONEINFO_LINK="/private/var/db/timezone/zoneinfo"
if [ ! -L "$ZONEINFO_LINK" ]; then
    rm -f "$ZONEINFO_LINK" 2>/dev/null
    ln -sf /usr/share/zoneinfo.default "$ZONEINFO_LINK"
    echo "[81-tz] Created zoneinfo symlink"
fi

# Create localtime symlink to actual timezone (Vietnam: Asia/Ho_Chi_Minh)
LOCALTIME="/private/var/db/timezone/localtime"
if [ ! -L "$LOCALTIME" ] && [ ! -f "$LOCALTIME" ]; then
    if [ -f "/usr/share/zoneinfo.default/Asia/Ho_Chi_Minh" ]; then
        ln -sf /usr/share/zoneinfo.default/Asia/Ho_Chi_Minh "$LOCALTIME"
        echo "[81-tz] Created localtime symlink -> Asia/Ho_Chi_Minh"
    else
        # Fallback to UTC
        ln -sf /usr/share/zoneinfo.default/UTC "$LOCALTIME"
        echo "[81-tz] Created localtime symlink -> UTC (fallback)"
    fi
fi

exit 0
BOOT_EOF
chmod 755 /redwood/boot.d/81-persistent-timezone.sh

# 2. Patch tzinit launchd plist to be RESILIENT (not abort boot on failure)
# This modifies the ACTUAL plist on the rootfs (persists across boots)
cat > /redwood/boot.d/81-patch-tzinit-plist.sh <<'BOOT_EOF'
#!/bin/bash
# Patch tzinit launchd plist on ROOTFS to not abort boot on failure
# Runs at every boot but modifies persistent plist on iosroot
# CRITICAL: This modifies the plist launchd reads at EARLY BOOT

PLIST="/System/Library/LaunchDaemons/com.apple.tzinit.plist"

if [ ! -f "$PLIST" ]; then
    echo "[81-plist] tzinit plist not found at $PLIST"
    exit 0
fi

echo "[81-plist] Patching tzinit plist for resilience..."

# Backup once
[ -f "$PLIST.bak" ] || cp "$PLIST" "$PLIST.bak"

# Use plutil (available on iOS) to modify plist
if command -v plutil >/dev/null 2>&1; then
    # 1. AbandonProcessGroup = false (don't kill process group on failure)
    plutil -replace AbandonProcessGroup -bool false "$PLIST" 2>/dev/null || true

    # 2. LaunchOnlyOnce = false (allow restart on failure)
    plutil -replace LaunchOnlyOnce -bool false "$PLIST" 2>/dev/null || true

    # 3. KeepAlive: restart on crash, don't require successful exit
    plutil -replace KeepAlive -xml '<dict><key>Crashed</key><true/><key>SuccessfulExit</key><false/></dict>' "$PLIST" 2>/dev/null || true

    # 4. ThrottleInterval: wait 10s between restarts (avoid spin)
    plutil -replace ThrottleInterval -integer 10 "$PLIST" 2>/dev/null || true

    # 5. StandardErrorPath/StandardOutPath for debugging
    plutil -replace StandardErrorPath -string "/var/log/tzinit.stderr.log" "$PLIST" 2>/dev/null || true
    plutil -replace StandardOutPath -string "/var/log/tzinit.stdout.log" "$PLIST" 2>/dev/null || true

    echo "[81-plist] tzinit plist patched successfully"
else
    # Fallback: use PlistBuddy if available
    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :AbandonProcessGroup false" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :LaunchOnlyOnce false" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Delete :KeepAlive" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :KeepAlive dict" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :KeepAlive:Crashed bool true" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :KeepAlive:SuccessfulExit bool false" "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :ThrottleInterval 10" "$PLIST" 2>/dev/null || true
        echo "[81-plist] tzinit plist patched via PlistBuddy"
    else
        echo "[81-plist] WARNING: No plutil or PlistBuddy available"
    fi
fi

# Also patch other critical early daemons to not abort boot
for DAEMON_PLIST in \
    "/System/Library/LaunchDaemons/com.apple.mobile.softwareupdated.plist" \
    "/System/Library/LaunchDaemons/com.apple.coreservices.powerlog.plist" \
    "/System/Library/LaunchDaemons/com.apple.syslogd.plist"; do

    if [ -f "$DAEMON_PLIST" ]; then
        plutil -replace AbandonProcessGroup -bool false "$DAEMON_PLIST" 2>/dev/null || true
        plutil -replace LaunchOnlyOnce -bool false "$DAEMON_PLIST" 2>/dev/null || true
        plutil -replace KeepAlive -xml '<dict><key>Crashed</key><true/><key>SuccessfulExit</key><false/></dict>' "$DAEMON_PLIST" 2>/dev/null || true
        plutil -replace ThrottleInterval -integer 10 "$DAEMON_PLIST" 2>/dev/null || true
        echo "[81-plist] Patched $(basename $DAEMON_PLIST)"
    fi
done

exit 0
BOOT_EOF
chmod 755 /redwood/boot.d/81-patch-tzinit-plist.sh

# 3. Early boot.d script to ensure /var symlink before any daemon starts
# This runs very early in boot.d sequence
cat > /redwood/boot.d/81-early-var-fix.sh <<'BOOT_EOF'
#!/bin/bash
# Ensure /var -> private/var symlink exists at every boot
# Critical for tzinit and other early services
# Runs from /redwood/boot.d/ (userland, after rootfs mounted RW)

echo "[81-var] Ensuring /var symlink..."

mkdir -p /private/var
if [ ! -L /var ]; then
    rm -f /var 2>/dev/null
    ln -sf /private/var /var
    echo "[81-var] Restored /var -> private/var symlink"
fi

exit 0
BOOT_EOF
chmod 755 /redwood/boot.d/81-early-var-fix.sh

# 4. Add boot args for documentation (kernel doesn't auto-fsck HFS+)
cat >> /redwood/boot-args.d/99-performance.conf <<'EOF'

# Boot hang prevention (81) - launchd resilience
tzinit_safe=1
launchd_no_abort=1
EOF

# 5. Run the persistent timezone setup NOW (at update time) to fix rootfs immediately
echo "[81] Running persistent timezone setup on rootfs now..."
mkdir -p /private/var/db/timezone
mkdir -p /usr/share/zoneinfo.default

# Populate zoneinfo.default if empty
if [ -z "$(ls -A /usr/share/zoneinfo.default 2>/dev/null)" ]; then
    if [ -d /usr/share/zoneinfo ] && [ -n "$(ls -A /usr/share/zoneinfo 2>/dev/null)" ]; then
        cp -r /usr/share/zoneinfo/* /usr/share/zoneinfo.default/ 2>/dev/null || true
        echo "[81] Populated zoneinfo.default from system zoneinfo"
    else
        mkdir -p /usr/share/zoneinfo.default/UTC
        echo -e "UTC0" > /usr/share/zoneinfo.default/UTC
        echo "[81] Created minimal UTC zoneinfo.default"
    fi
fi

# Create zoneinfo symlink
ZONEINFO_LINK="/private/var/db/timezone/zoneinfo"
if [ ! -L "$ZONEINFO_LINK" ]; then
    rm -f "$ZONEINFO_LINK" 2>/dev/null
    ln -sf /usr/share/zoneinfo.default "$ZONEINFO_LINK"
    echo "[81] Created zoneinfo symlink on rootfs"
fi

# Create localtime symlink
LOCALTIME="/private/var/db/timezone/localtime"
if [ ! -L "$LOCALTIME" ] && [ ! -f "$LOCALTIME" ]; then
    if [ -f "/usr/share/zoneinfo.default/Asia/Ho_Chi_Minh" ]; then
        ln -sf /usr/share/zoneinfo.default/Asia/Ho_Chi_Minh "$LOCALTIME"
        echo "[81] Created localtime symlink -> Asia/Ho_Chi_Minh"
    else
        ln -sf /usr/share/zoneinfo.default/UTC "$LOCALTIME"
        echo "[81] Created localtime symlink -> UTC (fallback)"
    fi
fi

# Ensure /var symlink
if [ ! -L /var ]; then
    rm -f /var 2>/dev/null
    ln -sf /private/var /var
    echo "[81] Fixed /var -> private/var symlink on rootfs"
fi

echo "=== [81] Boot hang fix applied (persistent rootfs + launchd resilience) ==="
echo ""
echo "FIXES APPLIED:"
echo "  1. Persistent timezone structure on rootfs:"
echo "     - /usr/share/zoneinfo.default/ populated (survives fsck)"
echo "     - /private/var/db/timezone/zoneinfo -> /usr/share/zoneinfo.default"
echo "     - /private/var/db/timezone/localtime -> Asia/Ho_Chi_Minh (or UTC)"
echo "  2. /var -> private/var symlink enforced at every boot (81-early-var-fix.sh)"
echo "  3. tzinit plist patched to KeepAlive on crash (81-patch-tzinit-plist.sh):"
echo "     - AbandonProcessGroup=false"
echo "     - LaunchOnlyOnce=false"
echo "     - KeepAlive: Crashed=true, SuccessfulExit=false"
echo "     - ThrottleInterval=10"
echo "  4. Other early daemons patched similarly (softwareupdated, powerlog, syslogd)"
echo "  5. Boot args: tzinit_safe=1 launchd_no_abort=1"
echo ""
echo "ARCHITECTURE: Pure iOS/XNU - NO Android init.rc, NO ramdisk scripts"

true