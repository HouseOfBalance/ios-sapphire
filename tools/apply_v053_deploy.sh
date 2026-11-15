#!/bin/bash
set -euo pipefail

echo "=== 1. Connect NBD ==="
insmod /home/khanh/modules/hfsplus.ko 2>/dev/null || true
nbd-client -d /dev/nbd0 2>/dev/null || true
HOST_IP=$(ip route | grep default | awk '{print $3}')
[ -z "$HOST_IP" ] && HOST_IP="172.20.160.1"
echo "Connecting to NBD server at $HOST_IP:10810..."
nbd-client "$HOST_IP" 10810 /dev/nbd0 -b 4096

mkdir -p /mnt/iosroot

echo "=== 2. Check and Repair HFS+ Volume ==="
fsck.hfsplus -y /dev/nbd0 || true

echo "=== 3. Mount HFS+ ==="
mount -t hfsplus -o force,rw /dev/nbd0 /mnt/iosroot

echo "=== 4. Ensure /var Symlink ==="
if [ ! -L /mnt/iosroot/var ]; then
    echo "Converting /var to symlink..."
    cp -a /mnt/iosroot/var/. /mnt/iosroot/private/var/ 2>/dev/null || true
    rm -rf /mnt/iosroot/var
    ln -s private/var /mnt/iosroot/var
fi

echo "=== 5. Deploy v0.5.3 Update Package into Redwood Inbox ==="
mkdir -p /mnt/iosroot/redwood/inbox
cp -f "/mnt/c/Users/TRAN VAN HUNG/Downloads/ios-sapphire/build_tmp/sapphire-update-0.5.3.supdate" /mnt/iosroot/redwood/inbox/
chmod 644 /mnt/iosroot/redwood/inbox/sapphire-update-0.5.3.supdate
ls -lh /mnt/iosroot/redwood/inbox/

echo "=== 6. Unpack and Pre-apply Steps Directly to /mnt/iosroot ==="
TMP_STEP=$(mktemp -d)
tar -xzf "/mnt/c/Users/TRAN VAN HUNG/Downloads/ios-sapphire/build_tmp/sapphire-update-0.5.3.supdate" -C "$TMP_STEP"

# Copy redwood steps & files
mkdir -p /mnt/iosroot/redwood/update/steps.d
cp -rf "$TMP_STEP"/steps/* /mnt/iosroot/redwood/update/steps.d/ 2>/dev/null || true
if [ -d "$TMP_STEP/root" ]; then
    cp -af "$TMP_STEP"/root/* /mnt/iosroot/ 2>/dev/null || true
fi

# Clean stray /Android.app at root
if [ -d /mnt/iosroot/Android.app ]; then
    rm -rf /mnt/iosroot/Android.app
fi

# Restore and re-sign /Applications/Android.app
LDID_HOST="/home/khanh/tools-dl/ldid/ldid"
ANDROID_ENT="/mnt/c/Users/TRAN VAN HUNG/Downloads/ios-sapphire/userland/dualboot/ios-app/AndroidBoot.entitlements"

mkdir -p /mnt/iosroot/Applications/Android.app
cp -af "$TMP_STEP"/root/Applications/Android.app/* /mnt/iosroot/Applications/Android.app/ 2>/dev/null || true
chown -R 0:0 /mnt/iosroot/Applications/Android.app
chmod -R 755 /mnt/iosroot/Applications/Android.app
chmod 755 /mnt/iosroot/Applications/Android.app/Android

if [ -x "$LDID_HOST" ] && [ -f "$ANDROID_ENT" ]; then
    "$LDID_HOST" -S"$ANDROID_ENT" /mnt/iosroot/Applications/Android.app/Android 2>/dev/null && \
        echo "  ✓ Re-signed /Applications/Android.app/Android"
fi

# Clean all bad CPU loop daemons
rm -f /mnt/iosroot/redwood/bin/volume-hud-daemon.sh
rm -f /mnt/iosroot/redwood/launchd/com.sapphire.volume-hud.plist
rm -f /mnt/iosroot/redwood/bin/dsi-brightness-bridge.sh
rm -f /mnt/iosroot/redwood/launchd/com.sapphire.dsi-brightness.plist
rm -f /mnt/iosroot/redwood/boot.d/84-publish-display-params.sh
rm -f /mnt/iosroot/redwood/bin/publish-display-params.sh
rm -f /mnt/iosroot/redwood/launchd/com.apple.corebrightnessd.plist
rm -f /mnt/iosroot/redwood/boot.d/73-sign-var-binaries.sh 2>/dev/null || true
rm -f /mnt/iosroot/redwood/bin/sign-var-binaries.sh 2>/dev/null || true

# Direct Sileo / APT Fix (Comprehensive)
echo "Applying Direct Sileo / APT HTTPS & permission fix..."
JB_PATH="/mnt/iosroot/private/var/jb"
mkdir -p "$JB_PATH/usr/lib/apt/methods"
mkdir -p "$JB_PATH/usr/libexec/apt/methods"

for mdir in "$JB_PATH/usr/lib/apt/methods" "$JB_PATH/usr/libexec/apt/methods"; do
    if [ -f "$mdir/http" ]; then
        ln -sf http "$mdir/https"
        chmod 755 "$mdir/https" "$mdir/http"
        echo "  ✓ Linked $mdir/https -> http"
    fi
done

# In case http only exists in one dir, symlink to the other
if [ -f "$JB_PATH/usr/lib/apt/methods/http" ] && [ ! -f "$JB_PATH/usr/libexec/apt/methods/http" ]; then
    ln -sf "$JB_PATH/usr/lib/apt/methods/http" "$JB_PATH/usr/libexec/apt/methods/http"
    ln -sf http "$JB_PATH/usr/libexec/apt/methods/https"
elif [ -f "$JB_PATH/usr/libexec/apt/methods/http" ] && [ ! -f "$JB_PATH/usr/lib/apt/methods/http" ]; then
    ln -sf "$JB_PATH/usr/libexec/apt/methods/http" "$JB_PATH/usr/lib/apt/methods/http"
    ln -sf http "$JB_PATH/usr/lib/apt/methods/https"
fi

mkdir -p "$JB_PATH/var/log"
chmod 777 "$JB_PATH/var/log"
touch "$JB_PATH/var/log/aptwrap.log"
chmod 666 "$JB_PATH/var/log/aptwrap.log"
chown 501:501 "$JB_PATH/var/log/aptwrap.log"

# Fix apt-get wrapper if it exists (redirect log to /tmp)
if [ -f "$JB_PATH/usr/bin/apt-get" ]; then
    sed -i 's|/var/jb/var/log/aptwrap.log|/tmp/aptwrap.log|g' "$JB_PATH/usr/bin/apt-get" 2>/dev/null || true
    echo "  ✓ Fixed apt-get wrapper log path to /tmp/aptwrap.log"
fi

# Ensure APT sandbox config exists with correct user (root)
mkdir -p "$JB_PATH/etc/apt/apt.conf.d"
APT_SANDBOX_CONF="$JB_PATH/etc/apt/apt.conf.d/20sapphire-sandbox.conf"
cat > "$APT_SANDBOX_CONF" <<'APTEOF'
APT::Sandbox::User "root";
Dir::Bin::methods "/var/jb/usr/lib/apt/methods";
Dir::Bin::solvers "/var/jb/usr/lib/apt/solvers";
APT::Sandbox::Seccomp "false";
DPkg::Pre-Install-Pkgs {"/var/jb/usr/libexec/dpkg-pre-install";};
APTEOF
chown 0:0 "$APT_SANDBOX_CONF"
chmod 644 "$APT_SANDBOX_CONF"
echo "  ✓ Created APT sandbox config"

# Ensure CaInfo is set for HTTPS
APT_CA_CONF="$JB_PATH/etc/apt/apt.conf.d/10sapphire.conf"
cat > "$APT_CA_CONF" <<'CAEOF'
Acquire::https::CaInfo "/var/jb/etc/ssl/certs/cacert.pem";
CAEOF
chown 0:0 "$APT_CA_CONF"
chmod 644 "$APT_CA_CONF"

# Direct Control Center Fix (enable Bluetooth & WiFi)
CC_PLIST="/mnt/iosroot/private/var/mobile/Library/Preferences/com.apple.controlcenter.plist"
if [ -f "$CC_PLIST" ]; then
    sed -i 's|<key>CCBluetoothModule</key>[[:space:]]*<false/>|<key>CCBluetoothModule</key><true/>|g' "$CC_PLIST" 2>/dev/null || true
    sed -i 's|<key>CCWiFiModule</key>[[:space:]]*<false/>|<key>CCWiFiModule</key><true/>|g' "$CC_PLIST" 2>/dev/null || true
    sed -i 's|<key>CCAirDropModule</key>[[:space:]]*<false/>|<key>CCAirDropModule</key><true/>|g' "$CC_PLIST" 2>/dev/null || true
    chown 501:501 "$CC_PLIST" 2>/dev/null || true
    chmod 600 "$CC_PLIST" 2>/dev/null || true
fi

# Restore Jailbreak Setuid & Permissions
if [ -d "$JB_PATH" ]; then
    echo "Restoring ownership and permissions on jailbreak..."
    chown -R 0:0 "$JB_PATH" 2>/dev/null || true
    chown -R 501:501 "$JB_PATH/var/mobile" 2>/dev/null || true
    chown -R 501:501 "$JB_PATH/var/lib/apt" 2>/dev/null || true
    chown -R 501:501 "$JB_PATH/var/cache/apt" 2>/dev/null || true
    chown -R 501:501 "$JB_PATH/tmp" 2>/dev/null || true

    echo "Restoring setuid 4755 on helpers..."
    [ -f "$JB_PATH/Applications/Sileo.app/giveMeRoot" ] && chmod 4755 "$JB_PATH/Applications/Sileo.app/giveMeRoot"
    [ -f "$JB_PATH/Applications/Zebra.app/giveMeRoot" ] && chmod 4755 "$JB_PATH/Applications/Zebra.app/giveMeRoot"
    [ -f "/mnt/iosroot/Applications/Sileo.app/giveMeRoot" ] && chmod 4755 "/mnt/iosroot/Applications/Sileo.app/giveMeRoot"
    [ -f "/mnt/iosroot/Applications/Zebra.app/giveMeRoot" ] && chmod 4755 "/mnt/iosroot/Applications/Zebra.app/giveMeRoot"

    [ -f "$JB_PATH/usr/bin/sudo" ] && chmod 4755 "$JB_PATH/usr/bin/sudo"
    [ -f "$JB_PATH/bin/su" ] && chmod 4755 "$JB_PATH/bin/su"
    [ -f "$JB_PATH/usr/bin/login" ] && chmod 4755 "$JB_PATH/usr/bin/login"
    [ -f "$JB_PATH/usr/bin/passwd" ] && chmod 4755 "$JB_PATH/usr/bin/passwd"
fi

rm -rf "$TMP_STEP"

echo "=== 7. Flush and Unmount Cleanly ==="
sync
umount /mnt/iosroot
nbd-client -d /dev/nbd0

echo "=== SUCCESS! v0.5.3 (SILEO + BLUETOOTH + TELEPHONY + XNU 4K) INSTALLED CLEANLY! ==="
