#!/bin/bash
# 05-fix-var-symlink.sh: Ensure /var -> private/var symlink integrity + timezone structure
set -e

if [ ! -L /var ] && [ -d /var ]; then
    echo "Fixing broken /var directory back to symlink..."
    # Copy any files that were accidentally extracted into /var over to /private/var
    cp -a /var/. /private/var/ 2>/dev/null || true
    rm -rf /var
    ln -s private/var /var
fi

# Ensure /var/mobile and /private/var/mobile permissions (UID 501 = mobile)
chown -R 501:501 /private/var/mobile/Library/Preferences 2>/dev/null || true
chmod 700 /private/var/mobile/Library/Preferences 2>/dev/null || true
chmod 600 /private/var/mobile/Library/Preferences/*.plist 2>/dev/null || true

# Ensure timezone structure exists (prevents tzinit exit code 2)
mkdir -p /private/var/db/timezone
mkdir -p /usr/share/zoneinfo.default

# Populate zoneinfo.default if empty
if [ -z "$(ls -A /usr/share/zoneinfo.default 2>/dev/null)" ]; then
    if [ -d /usr/share/zoneinfo ] && [ -n "$(ls -A /usr/share/zoneinfo 2>/dev/null)" ]; then
        cp -r /usr/share/zoneinfo/* /usr/share/zoneinfo.default/ 2>/dev/null || true
    else
        mkdir -p /usr/share/zoneinfo.default/UTC
        echo -e "UTC0" > /usr/share/zoneinfo.default/UTC
    fi
fi

# Create zoneinfo symlink: /private/var/db/timezone/zoneinfo -> /usr/share/zoneinfo.default
if [ ! -L /private/var/db/timezone/zoneinfo ]; then
    rm -f /private/var/db/timezone/zoneinfo 2>/dev/null
    ln -sf /usr/share/zoneinfo.default /private/var/db/timezone/zoneinfo
fi

# Create localtime symlink to Vietnam timezone (or UTC fallback)
if [ ! -L /private/var/db/timezone/localtime ] && [ ! -f /private/var/db/timezone/localtime ]; then
    if [ -f /usr/share/zoneinfo.default/Asia/Ho_Chi_Minh ]; then
        ln -sf /usr/share/zoneinfo.default/Asia/Ho_Chi_Minh /private/var/db/timezone/localtime
    else
        ln -sf /usr/share/zoneinfo.default/UTC /private/var/db/timezone/localtime
    fi
fi

true
