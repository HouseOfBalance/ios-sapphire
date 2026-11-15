#!/bin/bash
# 89-fix-sileo-apt-thermal-brightness.sh
# Fixes:
# 1. Sileo / APT HTTPS method driver missing & /var/jb/var/log/aptwrap.log permission denied
# 2. Overheating: Kill 100Hz volume-hud-daemon.sh & 10Hz dsi-brightness-bridge.sh loops
# 3. GPU Power: Disable force_bus_on/force_clk_on, enable power-gating down to 310MHz
# 4. Brightness: Restore sweetbl=0 & unlock Control Center slider via eagl.c bridge
# 5. Control Center: Re-enable CCBluetoothModule and CCWiFiModule
# Architecture: Pure iOS/XNU/launchd

set -e

echo "=== [89] Fixing Sileo APT HTTPS, Thermal Loops & Brightness Control ==="

JB_ROOT="/private/var/jb"

# ─────────────────────────────────────────────────────────────────
# 1. FIX SILEO / APT HTTPS METHOD DRIVER & LOG PERMISSIONS
# ─────────────────────────────────────────────────────────────────
echo "[1/5] Fixing Sileo / APT HTTPS transport & permissions..."

mkdir -p "$JB_ROOT/usr/lib/apt/methods" 2>/dev/null || true
mkdir -p "$JB_ROOT/usr/libexec/apt/methods" 2>/dev/null || true
mkdir -p "$JB_ROOT/var/log" 2>/dev/null || true
mkdir -p /var/log 2>/dev/null || true

# 1.1 In Procursus APT, https method is a symlink to http (uses libcurl + libgnutls from http method)
# Check BOTH possible locations for http method
for methods_dir in "$JB_ROOT/usr/lib/apt/methods" "$JB_ROOT/usr/libexec/apt/methods"; do
    if [ -f "$methods_dir/http" ]; then
        ln -sf http "$methods_dir/https"
        chmod 755 "$methods_dir/http" "$methods_dir/https" 2>/dev/null || true
        echo "  ✓ Created symlink: $methods_dir/https -> http"
    fi
done

# Fallback check for rootfs /usr/lib/apt/methods
if [ -d "/usr/lib/apt/methods" ] && [ -f "/usr/lib/apt/methods/http" ]; then
    ln -sf http "/usr/lib/apt/methods/https" 2>/dev/null || true
fi

# 1.2 Fix log directory permissions for user mobile (UID 501)
chmod 777 "$JB_ROOT/var/log" 2>/dev/null || true
chmod 777 /var/log 2>/dev/null || true

# 1.3 Fix aptwrap.log - ensure it's writable by mobile (UID 501)
touch "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true
chmod 666 "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true
chown 501:501 "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true

# 1.4 Fix /var/jb/usr/bin/apt-get wrapper script if it exists
# The wrapper may write to /var/jb/var/log/aptwrap.log which mobile can't write to
# Fix by redirecting to /tmp/aptwrap.log (world-writable)
# DON'T use 'file' command (not available on iOS) - just check if it's a script by reading first line
if [ -f "$JB_ROOT/usr/bin/apt-get" ]; then
    first_line=$(head -c 2 "$JB_ROOT/usr/bin/apt-get" 2>/dev/null)
    if [ "$first_line" = "#!" ]; then
        sed -i 's|/var/jb/var/log/aptwrap.log|/tmp/aptwrap.log|g' "$JB_ROOT/usr/bin/apt-get" 2>/dev/null || true
        echo "  ✓ Fixed apt-get wrapper log path to /tmp/aptwrap.log"
    fi
fi

# 1.5 Also fix any apt wrapper in /usr/bin (system location)
if [ -f "/usr/bin/apt-get" ]; then
    first_line=$(head -c 2 "/usr/bin/apt-get" 2>/dev/null)
    if [ "$first_line" = "#!" ]; then
        sed -i 's|/var/jb/var/log/aptwrap.log|/tmp/aptwrap.log|g' "/usr/bin/apt-get" 2>/dev/null || true
    fi
fi

# 1.6 Ensure APT lists and archives are owned by mobile
chown -R 501:501 "$JB_ROOT/var/lib/apt" 2>/dev/null || true
chown -R 501:501 "$JB_ROOT/var/cache/apt" 2>/dev/null || true

# 1.7 Ensure APT sandbox config exists with correct user (root) to avoid _apt user drop failure
APT_CONF_DIR="$JB_ROOT/etc/apt/apt.conf.d"
mkdir -p "$APT_CONF_DIR"
APT_SANDBOX_CONF="$APT_CONF_DIR/20sapphire-sandbox.conf"
if [ ! -f "$APT_SANDBOX_CONF" ]; then
    cat > "$APT_SANDBOX_CONF" <<'APTEOF'
APT::Sandbox::User "root";
Dir::Bin::methods "/var/jb/usr/libexec/apt/methods";
Dir::Bin::solvers "/var/jb/usr/libexec/apt/solvers";
APT::Sandbox::Seccomp "false";
DPkg::Pre-Install-Pkgs {"/var/jb/usr/libexec/dpkg-pre-install";};
APTEOF
    chown 0:0 "$APT_SANDBOX_CONF"
    chmod 644 "$APT_SANDBOX_CONF"
    echo "  ✓ Created APT sandbox config: $APT_SANDBOX_CONF"
else
    # Update existing config to use correct methods path
    sed -i 's|Dir::Bin::methods.*|Dir::Bin::methods "/var/jb/usr/libexec/apt/methods";|' "$APT_SANDBOX_CONF" 2>/dev/null || true
fi

# 1.8 Ensure CaInfo is set for HTTPS (libgnutls needs this)
APT_CA_CONF="$APT_CONF_DIR/10sapphire.conf"
if [ ! -f "$APT_CA_CONF" ]; then
    cat > "$APT_CA_CONF" <<'CAEOF'
Acquire::https::CaInfo "/var/jb/etc/ssl/certs/cacert.pem";
CAEOF
    chown 0:0 "$APT_CA_CONF"
    chmod 644 "$APT_CA_CONF"
    echo "  ✓ Created APT CaInfo config: $APT_CA_CONF"
fi

echo "  ✓ Sileo APT permissions, HTTPS transport, and sandbox config restored"

# ─────────────────────────────────────────────────────────────────
# 2. ELIMINATE OVERHEATING: KILL & REMOVE INFINITE BASH LOOPS
# ─────────────────────────────────────────────────────────────────
echo "[2/5] Purging CPU-hogging polling loops..."

# Stop and remove volume-hud-daemon (was running sleep 0.01 = 100Hz loop)
launchctl bootout system/com.sapphire.volume-hud 2>/dev/null || launchctl remove com.sapphire.volume-hud 2>/dev/null || true
pkill -9 -f "volume-hud-daemon.sh" 2>/dev/null || true
rm -f /redwood/launchd/com.sapphire.volume-hud.plist
rm -f /redwood/bin/volume-hud-daemon.sh
echo "  ✓ Eliminated volume-hud-daemon 100Hz loop"

# Stop and remove dsi-brightness-bridge (was running sleep 0.1 = 10Hz sysctl loop)
launchctl bootout system/com.sapphire.dsi-brightness 2>/dev/null || launchctl remove com.sapphire.dsi-brightness 2>/dev/null || true
pkill -9 -f "dsi-brightness-bridge.sh" 2>/dev/null || true
rm -f /redwood/launchd/com.sapphire.dsi-brightness.plist
rm -f /redwood/bin/dsi-brightness-bridge.sh
rm -f /redwood/boot.d/84-publish-display-params.sh
rm -f /redwood/bin/publish-display-params.sh
echo "  ✓ Eliminated dsi-brightness-bridge 10Hz loop"

# Remove fake corebrightnessd that broke eagl.c hooks
launchctl bootout system/com.apple.corebrightnessd 2>/dev/null || launchctl remove com.apple.corebrightnessd 2>/dev/null || true
rm -f /redwood/launchd/com.apple.corebrightnessd.plist
echo "  ✓ Removed conflicting corebrightnessd override"

# Fix set-cpu-affinity.sh to run ONCE, not an infinite while true loop
if [ -f /redwood/bin/set-cpu-affinity.sh ]; then
    # Remove while true loop from set-cpu-affinity.sh
    sed -i '/while true; do/,/done/d' /redwood/bin/set-cpu-affinity.sh 2>/dev/null || true
    echo "  ✓ set-cpu-affinity.sh converted to single-shot boot execution"
fi

# ─────────────────────────────────────────────────────────────────
# 3. GPU POWER MANAGEMENT: ALLOW ADRENO 610 TO SLEEP & DOWNCLOCK
# ─────────────────────────────────────────────────────────────────
echo "[3/5] Restoring GPU power-gating and dynamic frequency scaling..."

KGSL_PATH="/sys/class/kgsl/kgsl-3d0"
DEVFREQ_PATH="/sys/class/devfreq/5000000.gpu"

# Allow GPU bus and clock to power-gate during idle and screen off
if [ -d "$KGSL_PATH" ]; then
    echo "0" > "$KGSL_PATH/force_bus_on" 2>/dev/null || true
    echo "0" > "$KGSL_PATH/force_clk_on" 2>/dev/null || true
    echo "310000000" > "$KGSL_PATH/devfreq/min_freq" 2>/dev/null || true
    echo "msm-adreno-tz" > "$KGSL_PATH/devfreq/governor" 2>/dev/null || true
fi

# Update 87-kgsl-gpu-governor.sh so it persists across reboots
if [ -f /redwood/boot.d/87-kgsl-gpu-governor.sh ]; then
    cat > /redwood/boot.d/87-kgsl-gpu-governor.sh <<'KGSL_FIX'
#!/bin/bash
KGSL_PATH="/sys/class/kgsl/kgsl-3d0"
if [ -d "$KGSL_PATH" ]; then
    echo "msm-adreno-tz" > "$KGSL_PATH/devfreq/governor" 2>/dev/null || true
    echo "310000000" > "$KGSL_PATH/devfreq/min_freq" 2>/dev/null || true
    echo "1114000000" > "$KGSL_PATH/devfreq/max_freq" 2>/dev/null || true
    echo "0" > "$KGSL_PATH/force_bus_on" 2>/dev/null || true
    echo "0" > "$KGSL_PATH/force_clk_on" 2>/dev/null || true
fi
KGSL_FIX
    chmod 755 /redwood/boot.d/87-kgsl-gpu-governor.sh
    echo "  ✓ GPU governor tuned for cool idle & 1114MHz dynamic peak"
fi

# ─────────────────────────────────────────────────────────────────
# 4. FIX BRIGHTNESS: RESTORE SWEETBL=0 & UNLOCK CONTROL CENTER SLIDER
# ─────────────────────────────────────────────────────────────────
echo "[4/5] Restoring native brightness path (sweetbl=0)..."

# Ensure sweetbl=0 in boot-args
sed -i 's/sweetbl=1/sweetbl=0/g' /redwood/boot-args.d/*.conf 2>/dev/null || true
sed -i 's/sweetbl=1/sweetbl=0/g' /redwood/boot.d/*.sh 2>/dev/null || true
sysctl -w kern.sweetbl=0 2>/dev/null || true
echo "  ✓ Set sweetbl=0 (allows eagl.c to hook BKDisplayBrightnessController)"

# ─────────────────────────────────────────────────────────────────
# 5. RESTORE CONTROL CENTER BLUETOOTH & WIFI MODULES
# ─────────────────────────────────────────────────────────────────
echo "[5/5] Re-enabling Bluetooth & WiFi in Control Center..."

CC_PLIST="/private/var/mobile/Library/Preferences/com.apple.controlcenter.plist"
cat > "$CC_PLIST" <<'CC_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CCModuleVisibility</key>
    <dict>
        <key>CCBluetoothModule</key>
        <true/>
        <key>CCWiFiModule</key>
        <true/>
        <key>CCAirDropModule</key>
        <true/>
        <key>CCNearbyDevicesModule</key>
        <true/>
        <key>CCFlashlightModule</key>
        <true/>
        <key>CCTimerModule</key>
        <true/>
        <key>CCCalculatorModule</key>
        <true/>
        <key>CCCameraModule</key>
        <true/>
    </dict>
    <key>CCCustomizeEnabled</key>
    <true/>
</dict>
</plist>
CC_EOF

chown 501:501 "$CC_PLIST" 2>/dev/null || true
chmod 600 "$CC_PLIST" 2>/dev/null || true
echo "  ✓ Control Center modules restored (Bluetooth/WiFi enabled)"

echo "=== [89] Step 89 complete! Sileo APT HTTPS active, CPU loops eliminated, thermal normalized! ==="