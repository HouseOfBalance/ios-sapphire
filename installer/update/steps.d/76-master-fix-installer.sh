#!/bin/bash
# 76-master-fix-installer.sh: Master installer for all fixes + Master Mission (83-86)
# Runs after all individual fix scripts to ensure proper ordering and verification
# Uses relative paths from script location - compatible with iOS target
# Architecture: Pure iOS/XNU/launchd - NO Android init.rc, NO ramdisk

set -e

# Get the directory where this script lives (works on iOS/sapphire)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_SAPPHIRE_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

JB_ROOT="/private/var/jb"
JB_APPS="$JB_ROOT/Applications"

echo "=== [76] Master Fix Installer - Applying All Fixes (70-75, 80-86) ==="
echo "Script dir: $SCRIPT_DIR"
echo "iOS Sapphire root: $IOS_SAPPHIRE_ROOT"

# Ensure all fix scripts are executable (70-75 + 80-86)
for script in "$SCRIPT_DIR"/7[0-5]-*.sh "$SCRIPT_DIR"/8[0-6]-*.sh; do
    [ -f "$script" ] && chmod 755 "$script"
done

# 1. Verify critical prerequisites
echo "Checking prerequisites..."

# Check kernel patches are applied (0156 for AMFI, 0333-0343 for fluidity)
if sysctl -n security.mac.amfi.developer_mode_status 2>/dev/null | grep -q 1; then
    echo "  ✓ AMFI sysctl present (0156-sapphire-amfi.patch applied)"
else
    echo "  ⚠ WARNING: AMFI sysctl not found - kernel may need rebuild with 0156"
fi

# 2. Run all fix scripts in order
echo "Running individual fix scripts..."

# 65: Bluetooth Capability Tweak (must run before 71)
if [ -f "$SCRIPT_DIR/65-bluetooth-capability-tweak.sh" ]; then
    bash "$SCRIPT_DIR/65-bluetooth-capability-tweak.sh"
fi

# 70: Wallpaper/PosterBoard
if [ -f "$SCRIPT_DIR/70-wallpaper-posterboard-fix.sh" ]; then
    bash "$SCRIPT_DIR/70-wallpaper-posterboard-fix.sh"
fi

# 71: Bluetooth Audio
if [ -f "$SCRIPT_DIR/71-bluetooth-audio-routing-fix.sh" ]; then
    bash "$SCRIPT_DIR/71-bluetooth-audio-routing-fix.sh"
fi

# 72: Android IPA Install
if [ -f "$SCRIPT_DIR/72-android-ipa-install-fix.sh" ]; then
    bash "$SCRIPT_DIR/72-android-ipa-install-fix.sh"
fi

# 73: TrollStore AMFI
if [ -f "$SCRIPT_DIR/73-trollstore-amfi-fix.sh" ]; then
    bash "$SCRIPT_DIR/73-trollstore-amfi-fix.sh"
fi

# 74: YouTube Music Web
if [ -f "$SCRIPT_DIR/74-youtube-music-web-fix.sh" ]; then
    bash "$SCRIPT_DIR/74-youtube-music-web-fix.sh"
fi

# 75: Brightness Control (REMOVED - superseded by 84 Fix Brightness CoreBrightness)
# if [ -f "$SCRIPT_DIR/75-brightness-control-fix.sh" ]; then
#     bash "$SCRIPT_DIR/75-brightness-control-fix.sh"
# fi

# 80: Control Center Freeze Fix (CRITICAL - prevents full system deadlock)
if [ -f "$SCRIPT_DIR/80-controlcenter-freeze-fix.sh" ]; then
    bash "$SCRIPT_DIR/80-controlcenter-freeze-fix.sh"
fi

# 81: Boot Hang Fix (CRITICAL - prevents stuck at core zlib after hard reset)
if [ -f "$SCRIPT_DIR/81-boot-hang-fix.sh" ]; then
    bash "$SCRIPT_DIR/81-boot-hang-fix.sh"
fi

# 82: Restore Jailbreak Permissions (CRITICAL - fixes Sileo crash & Zebra Demo Mode)
if [ -f "$SCRIPT_DIR/82-restore-jailbreak-permissions.sh" ]; then
    bash "$SCRIPT_DIR/82-restore-jailbreak-permissions.sh"
fi

# 83: Fix Respring Loop (MASTER MISSION - SafeMode, watchdog, jetsam, prefs)
if [ -f "$SCRIPT_DIR/83-fix-respring-loop.sh" ]; then
    bash "$SCRIPT_DIR/83-fix-respring-loop.sh"
fi

# 84: Fix Brightness (MASTER MISSION - CoreBrightness + DSI DCS 0x51)
if [ -f "$SCRIPT_DIR/84-fix-brightness-corebrightness.sh" ]; then
    bash "$SCRIPT_DIR/84-fix-brightness-corebrightness.sh"
fi

# 85: Ultra Fluidity (MASTER MISSION - CPU affinity, VSync interrupt, Mesa tuning)
if [ -f "$SCRIPT_DIR/85-ultra-fluidity-cpu-affinity.sh" ]; then
    bash "$SCRIPT_DIR/85-ultra-fluidity-cpu-affinity.sh"
fi

# 86: Full Hardware Parity (MASTER MISSION - sensors, haptics, battery, safe area, Touch ID)
if [ -f "$SCRIPT_DIR/86-full-hardware-parity.sh" ]; then
    bash "$SCRIPT_DIR/86-full-hardware-parity.sh"
fi

# 87: Zero-Jank Ultra Fluidity (PHASE 4 - GPU KGSL, Touch IRQ, CA Culling, CPU EAS, VM/I/O)
if [ -f "$SCRIPT_DIR/87-zero-jank-ultra-fluidity.sh" ]; then
    bash "$SCRIPT_DIR/87-zero-jank-ultra-fluidity.sh"
fi

# 88: Fix Android Dual-Boot Switcher App (restore entitlements & permissions)
if [ -f "$SCRIPT_DIR/88-fix-android-boot-app.sh" ]; then
    bash "$SCRIPT_DIR/88-fix-android-boot-app.sh"
fi

# 89: Fix Sileo APT HTTPS, Thermal Loops & Brightness Control
if [ -f "$SCRIPT_DIR/89-fix-sileo-apt-thermal-brightness.sh" ]; then
    bash "$SCRIPT_DIR/89-fix-sileo-apt-thermal-brightness.sh"
fi

# 90: Deploy Telephony Stack (ccstart, bbstart, ccbridge.dylib, libsapphire-fakebb.dylib)
# Fixes: CommCenter crash loop (180% CPU), locationd/abm-helper crash every 15-18s
if [ -f "$SCRIPT_DIR/90-telephony-stack.sh" ]; then
    bash "$SCRIPT_DIR/90-telephony-stack.sh"
fi

# 2.5. Deploy telephony components (ccstart, ccbridge.dylib) for SIM/Service fix
echo "Deploying telephony components (ccstart, ccbridge.dylib)..."
mkdir -p /redwood/bin /redwood/lib
if [ -f "$IOS_SAPPHIRE_ROOT/userland/obj/ccstart" ]; then
    cp -f "$IOS_SAPPHIRE_ROOT/userland/obj/ccstart" /redwood/bin/ccstart
    chmod 755 /redwood/bin/ccstart
    /var/jb/usr/bin/ldid -S /redwood/bin/ccstart 2>/dev/null || true
    echo "  ✓ ccstart deployed to /redwood/bin/ccstart"
else
    echo "  ⚠ ccstart not found at $IOS_SAPPHIRE_ROOT/userland/obj/ccstart"
fi

if [ -f "$IOS_SAPPHIRE_ROOT/userland/obj/ccbridge.dylib" ]; then
    cp -f "$IOS_SAPPHIRE_ROOT/userland/obj/ccbridge.dylib" /redwood/lib/ccbridge.dylib
    chmod 644 /redwood/lib/ccbridge.dylib
    echo "  ✓ ccbridge.dylib deployed to /redwood/lib/ccbridge.dylib"
else
    echo "  ⚠ ccbridge.dylib not found at $IOS_SAPPHIRE_ROOT/userland/obj/ccbridge.dylib"
fi

# Also deploy qmitool and pdpnet if not already present
if [ -f "$IOS_SAPPHIRE_ROOT/userland/obj/qmitool" ] && [ ! -f /redwood/bin/qmitool ]; then
    cp -f "$IOS_SAPPHIRE_ROOT/userland/obj/qmitool" /redwood/bin/qmitool
    chmod 4755 /redwood/bin/qmitool
    /var/jb/usr/bin/ldid -S /redwood/bin/qmitool 2>/dev/null || true
    echo "  ✓ qmitool deployed to /redwood/bin/qmitool"
fi

if [ -f "$IOS_SAPPHIRE_ROOT/userland/obj/pdpnet" ] && [ ! -f /redwood/bin/pdpnet ]; then
    cp -f "$IOS_SAPPHIRE_ROOT/userland/obj/pdpnet" /redwood/bin/pdpnet
    chmod 755 /redwood/bin/pdpnet
    /var/jb/usr/bin/ldid -S /redwood/bin/pdpnet 2>/dev/null || true
    echo "  ✓ pdpnet deployed to /redwood/bin/pdpnet"
fi

# 2.6. Update CommCenter launchd job to use ccstart wrapper
echo "Updating CommCenter launchd job to use ccstart..."
PLIST_CACHE="/System/Library/xpc/launchd.plist"
if [ -f "$PLIST_CACHE" ]; then
    # Backup if not already backed up
    [ -f /var/root/launchd.plist.pre-ccstart ] || cp -p "$PLIST_CACHE" /var/root/launchd.plist.pre-ccstart

    # Use plistop to update the CommCenter job
    P=/redwood/bin/plistop
    if [ -x "$P" ]; then
        # Update ProgramArguments to use ccstart
        $P "$PLIST_CACHE" set "LaunchDaemons:/System/Library/LaunchDaemons/com.apple.CommCenter.plist:ProgramArguments" array "/redwood/bin/ccstart" 2>/dev/null && \
            echo "  ✓ CommCenter launchd updated to use ccstart" || \
            echo "  ⚠ Failed to update CommCenter launchd (plistop may not support array set)"
    else
        echo "  ⚠ plistop not found at $P, cannot update launchd cache"
    fi
else
    echo "  ⚠ Launchd cache not found at $PLIST_CACHE"
fi

# 3. Verify all launchd jobs are loaded
echo "Loading launchd jobs..."
L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl

JOBS=(
    "com.sapphire.ipa-install"
    "com.sapphire.sign-binaries"
    "com.sapphire.btmonitor"
    "com.sapphire.respring-monitor"
    "com.sapphire.cpu-affinity"
    "com.sapphire.sensord"
    "com.sapphire.vibd"
    "com.sapphire.thermald"
    "com.sapphire.touchid-bridge"
)

for job in "${JOBS[@]}"; do
    plist="/redwood/launchd/${job}.plist"
    if [ -f "$plist" ]; then
        "$L" load "$plist" 2>/dev/null || true
        echo "  Loaded: $job"
    fi
done

# 4. Run boot.d scripts (70-75 + 80-87 for all fixes)
echo "Running boot.d scripts..."
for boot_script in /redwood/boot.d/7[0-5]-*.sh /redwood/boot.d/8[0-7]-*.sh; do
    if [ -f "$boot_script" ]; then
        bash "$boot_script" 2>/dev/null || true
    fi
done

# 5. Final verification
echo ""
echo "=== Verification ==="

# Check preferences (70-75 + 80-81 - REAL keys only)
for pref in \
    com.apple.PosterBoard.plist \
    com.apple.ImageIO.plist \
    com.apple.mobilesafari.plist \
    com.apple.WebKit.WebContent.plist \
    com.apple.Accessibility.plist \
    com.apple.controlcenter.plist; do
    if [ -f "/private/var/mobile/Library/Preferences/$pref" ]; then
        echo "  ✓ $pref present"
    else
        echo "  ⚠ $pref missing"
    fi
done

# Check kernel patches
echo ""
echo "Kernel sysctls:"
sysctl -n security.mac.amfi.developer_mode_status 2>/dev/null && echo "  ✓ AMFI developer_mode_status" || echo "  ✗ AMFI missing"
sysctl -n kern.sweet_sched 2>/dev/null && echo "  ✓ sweet_sched" || echo "  ✗ sweet_sched missing"
sysctl -n kern.sapphire_mesa_gmem 2>/dev/null && echo "  ✓ sapphire_mesa_gmem (0347)" || echo "  ✗ sapphire_mesa_gmem missing"
sysctl -n kern.sapphire_affinity 2>/dev/null && echo "  ✓ sapphire_affinity (CPU pinning, 0348)" || echo "  ⚠ sapphire_affinity missing"
sysctl -n kern.sweet_gpu_fence 2>/dev/null && echo "  ✓ sweet_gpu_fence (GPU fence adaptive, 0349)" || echo "  ⚠ sweet_gpu_fence missing"
sysctl -n kern.sweet_dsi_cmd 2>/dev/null && echo "  ✓ sweet_dsi_cmd (DSI brightness, 0345/0346)" || echo "  ⚠ sweet_dsi_cmd missing"

# Check daemons
echo ""
echo "Critical daemons:"
for d in assetsd photoanalysisd bluetoothd mediaserverd; do
    if pgrep -x "$d" >/dev/null; then
        echo "  ✓ $d running"
    else
        echo "  ⚠ $d not running"
    fi
done

# Check CommCenter and telephony
echo ""
echo "Telephony / SIM Service:"
if pgrep -x "CommCenter" >/dev/null; then
    echo "  ✓ CommCenter running"
    # Check if ccbridge is loaded
    if grep -q ccbridge.dylib /proc/$(pgrep -x CommCenter)/maps 2>/dev/null; then
        echo "  ✓ ccbridge.dylib injected into CommCenter"
    else
        echo "  ⚠ ccbridge.dylib NOT injected - check DYLD_INSERT_LIBRARIES"
    fi
else
    echo "  ✗ CommCenter NOT running"
fi

# Check telephony binaries
for bin in ccstart bbstart qmitool pdpnet; do
    if [ -x "/redwood/bin/$bin" ]; then
        echo "  ✓ /redwood/bin/$bin present"
    else
        echo "  ✗ /redwood/bin/$bin MISSING"
    fi
done

for lib in ccbridge.dylib libsapphire-fakebb.dylib libredwood-gl.dylib libredwood-glload.dylib; do
    if [ -f "/redwood/lib/$lib" ]; then
        echo "  ✓ /redwood/lib/$lib present"
    else
        echo "  ✗ /redwood/lib/$lib MISSING"
    fi
done

# Check CommCenter launchd plist uses ccstart
COMM_CENTER_PLIST="/System/Library/LaunchDaemons/com.apple.CommCenter.plist"
if [ -f "$COMM_CENTER_PLIST" ]; then
    if grep -q "/redwood/bin/ccstart" "$COMM_CENTER_PLIST" 2>/dev/null || plutil -p "$COMM_CENTER_PLIST" 2>/dev/null | grep -q ccstart; then
        echo "  ✓ CommCenter launchd uses ccstart wrapper"
    else
        echo "  ⚠ CommCenter launchd may not use ccstart"
    fi
fi

# Check locationd and abm-helper use bbstart
LOCATIOND_PLIST="/System/Library/LaunchDaemons/com.apple.locationd.plist"
if [ -f "$LOCATIOND_PLIST" ]; then
    if grep -q "/redwood/bin/bbstart" "$LOCATIOND_PLIST" 2>/dev/null; then
        echo "  ✓ locationd launchd uses bbstart wrapper"
    else
        echo "  ⚠ locationd launchd may not use bbstart"
    fi
fi

ABM_HELPER_PLIST="/System/Library/LaunchDaemons/com.apple.abm-helper.plist"
if [ -f "$ABM_HELPER_PLIST" ]; then
    if grep -q "/redwood/bin/bbstart" "$ABM_HELPER_PLIST" 2>/dev/null; then
        echo "  ✓ abm-helper launchd uses bbstart wrapper"
    else
        echo "  ⚠ abm-helper launchd may not use bbstart"
    fi
fi

# Check dasd and aggregated are disabled (CPU hogs)
echo ""
echo "CPU-hogging daemons (should be disabled):"
for daemon in com.apple.dasd com.apple.aggregated; do
    if pgrep -x "$daemon" >/dev/null; then
        echo "  ⚠ $daemon RUNNING (should be disabled)"
    else
        echo "  ✓ $daemon disabled"
    fi
done

# Check coreduetd is enabled (CRITICAL for location)
if pgrep -x "coreduetd" >/dev/null; then
    echo "  ✓ coreduetd running (CRITICAL for location)"
else
    echo "  ⚠ coreduetd NOT running (location will fail)"
fi

# Kernel patches are verified via sysctls above (not by checking /redwood/patches which
# contains reference patches from step 87 that may have different numbers/content)
echo ""
echo "Kernel patches: VERIFIED VIA SYSCTLS (see 'Kernel sysctls' section above)"
echo "  Actual kernel patches are in xnu/patches/ and built into the kernel."
echo "  /redwood/patches/ contains reference patches from step 87 (different numbering)."

# Check critical fix scripts
echo ""
echo "Critical fix scripts (80-87):"
for script in \
    80-controlcenter-freeze-fix.sh \
    81-boot-hang-fix.sh \
    82-restore-jailbreak-permissions.sh \
    83-fix-respring-loop.sh \
    84-fix-brightness-corebrightness.sh \
    85-ultra-fluidity-cpu-affinity.sh \
    86-full-hardware-parity.sh \
    87-zero-jank-ultra-fluidity.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        echo "  ✓ $script"
    else
        echo "  ⚠ $script missing"
    fi
done

# Check boot.d scripts for critical fixes
echo ""
echo "Boot.d scripts for critical fixes (80-87):"
for boot_script in \
    80-controlcenter-gl-args.sh \
    81-patch-tzinit-plist.sh \
    81-early-var-fix.sh \
    81-persistent-timezone.sh \
    83-gpu-fence-mitigation.sh \
    83-tweak-validation.sh \
    84-publish-display-params.sh \
    85-ca-aggressive-culling.sh \
    85-touch-optimization.sh \
    85-vm-compressor.sh \
    85-displaylink-120hz.sh \
    85-scheduler-tuning.sh \
    85-gpu-fence-adaptive.sh \
    86-install-kexts.sh \
    87-kgsl-gpu-governor.sh \
    87-touch-irq-affinity.sh \
    87-quartzcore-render-tuning.sh \
    87-cpu-eas-scheduler.sh \
    87-vm-io-tuning.sh; do
    if [ -f "/redwood/boot.d/$boot_script" ]; then
        echo "  ✓ $boot_script"
    else
        echo "  ⚠ $boot_script missing"
    fi
done

# Check gl.args
echo ""
echo "gl.args (vblur=0 for Control Center freeze fix):"
for gl_args in /var/tmp/gl.args /private/var/tmp/gl.args /redwood/gl.args; do
    if [ -f "$gl_args" ] && grep -q "vblur=0" "$gl_args"; then
        echo "  ✓ $gl_args: $(cat $gl_args)"
    else
        echo "  ⚠ $gl_args missing or wrong vblur value"
    fi
done

# Check timezone structure
echo ""
echo "Timezone structure (boot hang fix):"
for tz_file in \
    "/usr/share/zoneinfo.default" \
    "/private/var/db/timezone/zoneinfo" \
    "/private/var/db/timezone/localtime" \
    "/var -> private/var"; do
    if [ "$tz_file" = "/var -> private/var" ]; then
        if [ -L /var ] && [ "$(readlink /var)" = "private/var" ]; then
            echo "  ✓ /var symlink correct"
        else
            echo "  ⚠ /var symlink broken"
        fi
    elif [ -e "$tz_file" ]; then
        echo "  ✓ $tz_file exists"
    else
        echo "  ⚠ $tz_file missing"
    fi
done

# Check tzinit plist patch
echo ""
echo "tzinit plist resilience:"
PLIST="/System/Library/LaunchDaemons/com.apple.tzinit.plist"
if [ -f "$PLIST" ]; then
    if plutil -p "$PLIST" 2>/dev/null | grep -q "AbandonProcessGroup.*0"; then
        echo "  ✓ tzinit plist patched (AbandonProcessGroup=false)"
    else
        echo "  ⚠ tzinit plist not patched"
    fi
else
    echo "  ⚠ tzinit plist not found"
fi

# Check Bluetooth Capability Tweak (65)
echo ""
echo "Bluetooth Capability Tweak (65):"
if [ -f /var/jb/usr/lib/TweakInject/SapphireBTCapability.dylib ]; then
    echo "  ✓ SapphireBTCapability.dylib installed in TweakInject"
else
    echo "  ⚠ SapphireBTCapability.dylib missing from TweakInject"
fi
if [ -f /var/jb/usr/lib/TweakInject/SapphireBTCapability.plist ]; then
    echo "  ✓ SapphireBTCapability.plist installed in TweakInject"
    if plutil -p /var/jb/usr/lib/TweakInject/SapphireBTCapability.plist 2>/dev/null | grep -q "com.apple.springboard"; then
        echo "  ✓ Filter includes SpringBoard"
    fi
    if plutil -p /var/jb/usr/lib/TweakInject/SapphireBTCapability.plist 2>/dev/null | grep -q "com.apple.Preferences"; then
        echo "  ✓ Filter includes Preferences"
    fi
    if plutil -p /var/jb/usr/lib/TweakInject/SapphireBTCapability.plist 2>/dev/null | grep -q "com.apple.BluetoothManager"; then
        echo "  ✓ Filter includes BluetoothManager"
    fi
else
    echo "  ⚠ SapphireBTCapability.plist missing from TweakInject"
fi

# Check Master Mission: Respring Loop Fix (83)
echo ""
echo "Master Mission - Respring Loop (83):"
if [ -f /redwood/bin/respring-monitor.sh ]; then
    echo "  ✓ respring-monitor.sh installed"
else
    echo "  ⚠ respring-monitor.sh missing"
fi
if [ -f /redwood/launchd/com.sapphire.respring-monitor.plist ]; then
    echo "  ✓ respring-monitor launchd"
else
    echo "  ⚠ respring-monitor launchd missing"
fi
SAFEMODE="/redwood/safemode"
if [ -f "$SAFEMODE" ]; then
    echo "  ⚠ SafeMode ACTIVE (check stability)"
else
    echo "  ✓ SafeMode inactive"
fi
if [ -f /private/var/db/jetsam_properties_override.plist ]; then
    echo "  ✓ Jetsam override installed"
else
    echo "  ⚠ Jetsam override missing"
fi

# Check Master Mission: Brightness (84)
echo ""
echo "Master Mission - Brightness (84):"
if [ -f /redwood/launchd/com.apple.corebrightnessd.plist ]; then
    echo "  ✓ corebrightnessd launchd"
else
    echo "  ⚠ corebrightnessd launchd missing"
fi
if [ -f /redwood/bin/publish-display-params.sh ]; then
    echo "  ✓ publish-display-params.sh"
else
    echo "  ⚠ publish-display-params.sh missing"
fi
if [ -f /redwood/launchd/com.sapphire.dsi-brightness-bridge.plist ]; then
    echo "  ✓ DSI brightness bridge launchd"
else
    echo "  ⚠ DSI brightness bridge launchd missing"
fi
# Check IODisplayParameters sysctls
for sysctl_name in kern.sapphire_backlight_min kern.sapphire_backlight_max kern.sapphire_backlight_current kern.sapphire_backlight_linear; do
    if sysctl -n "$sysctl_name" 2>/dev/null >/dev/null; then
        echo "  ✓ $sysctl_name"
    else
        echo "  ⚠ $sysctl_name missing"
    fi
done

# Check Master Mission: Ultra Fluidity (85)
echo ""
echo "Master Mission - Ultra Fluidity (85):"
if [ -f /redwood/bin/set-cpu-affinity.sh ]; then
    echo "  ✓ CPU affinity script"
else
    echo "  ⚠ CPU affinity script missing"
fi
if [ -f /redwood/launchd/com.sapphire.cpu-affinity.plist ]; then
    echo "  ✓ CPU affinity launchd"
else
    echo "  ⚠ CPU affinity launchd missing"
fi
if [ -f /redwood/glenv ]; then
    echo "  ✓ Mesa glenv configured"
else
    echo "  ⚠ Mesa glenv missing"
fi
for sysctl_name in kern.sweet_sched kern.sapphire_ca_color_opaque kern.sapphire_ca_shadow_quality kern.sapphire_ca_max_backdrop_layers kern.sapphire_ca_force_dirty_rects; do
    if sysctl -n "$sysctl_name" 2>/dev/null >/dev/null; then
        echo "  ✓ $sysctl_name = $(sysctl -n "$sysctl_name" 2>/dev/null)"
    else
        echo "  ⚠ $sysctl_name missing"
    fi
done

# Check Master Mission: Hardware Parity (86)
echo ""
echo "Master Mission - Hardware Parity (86):"
for kext in SweetSensors SweetBattery SweetTouchID; do
    if [ -f "/redwood/kexts/$kext.kext/Contents/Info.plist" ]; then
        echo "  ✓ $kext.kext staged"
    else
        echo "  ⚠ $kext.kext missing"
    fi
done
if [ -f /redwood/launchd/com.sapphire.volume-hud.plist ]; then
    echo "  ✓ Volume HUD launchd"
else
    echo "  ⚠ Volume HUD launchd missing"
fi
if [ -f /redwood/launchd/com.sapphire.sensord.plist ]; then
    echo "  ✓ Sensor daemon (sensord) launchd"
else
    echo "  ⚠ Sensor daemon (sensord) launchd missing"
fi
if [ -f /redwood/launchd/com.sapphire.vibd.plist ]; then
    echo "  ✓ Haptic daemon (vibd) launchd"
else
    echo "  ⚠ Haptic daemon (vibd) launchd missing"
fi
if [ -f /redwood/launchd/com.sapphire.thermald.plist ]; then
    echo "  ✓ Thermal daemon (thermald) launchd"
else
    echo "  ⚠ Thermal daemon (thermald) launchd missing"
fi
if [ -f /redwood/launchd/com.sapphire.touchid-bridge.plist ]; then
    echo "  ✓ TouchID bridge launchd"
else
    echo "  ⚠ TouchID bridge launchd missing"
fi
# Hardware parity binaries (fixes overheating from placeholder daemons)
if [ -x /redwood/bin/sensord ]; then
    echo "  ✓ sensord binary installed"
else
    echo "  ⚠ sensord binary missing (build from userland/sensors/)"
fi
if [ -x /redwood/bin/vibd ]; then
    echo "  ✓ vibd binary installed"
else
    echo "  ⚠ vibd binary missing (build from userland/haptics/)"
fi
if [ -x /redwood/bin/thermald ]; then
    echo "  ✓ thermald binary installed"
else
    echo "  ⚠ thermald binary missing (build from userland/thermal/)"
fi
# SapphireHaptics.dylib tweak
if [ -f /System/Library/Frameworks/UIKit.framework/SapphireHaptics.dylib ] || [ -f /Library/MobileSubstrate/DynamicLibraries/SapphireHaptics.dylib ]; then
    echo "  ✓ SapphireHaptics.dylib installed"
else
    echo "  ⚠ SapphireHaptics.dylib missing (build from userland/haptics/)"
fi
# RedwoodAudio.driver
if [ -d /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver ]; then
    echo "  ✓ RedwoodAudio.driver installed"
else
    echo "  ⚠ RedwoodAudio.driver missing (build from userland/audio/)"
fi
# Safe area
if grep -q "SBStatusBarPaddingTop" /private/var/mobile/Library/Preferences/com.apple.springboard.plist 2>/dev/null; then
    echo "  ✓ Punch-hole safe area configured"
else
    echo "  ⚠ Punch-hole safe area missing"
fi
# CC modules
if grep -q "Mute.*true" /private/var/mobile/Library/Preferences/com.apple.controlcenter.plist 2>/dev/null; then
    echo "  ✓ CC Mute module enabled"
else
    echo "  ⚠ CC Mute module missing"
fi

# Check Master Mission: Zero-Jank Ultra Fluidity (87 - PHASE 4)
echo ""
echo "Master Mission - Zero-Jank Ultra Fluidity (87 - PHASE 4):"
for sysctl_name in \
    kern.sapphire_ca_disable_blur \
    kern.sapphire_ca_halfres_backdrop \
    kern.sapphire_ca_force_dirty_rects \
    kern.sapphire_ca_shadow_quality \
    kern.sapphire_ca_max_backdrop_layers \
    kern.sapphire_ca_color_opaque \
    kern.sapphire_dl_force_120hz \
    kern.sapphire_fb_triple_buffer \
    kern.sapphire_fb_max_inflight \
    kern.sapphire_fb_event_driven \
    kern.sapphire_mesa_gmem \
    kern.sapphire_mesa_glthread \
    kern.sweet_sched \
    kern.sched_amp_prefer_perf \
    vm.dirty_ratio \
    vm.compressor_mode; do
    if sysctl -n "$sysctl_name" 2>/dev/null >/dev/null; then
        echo "  ✓ $sysctl_name = $(sysctl -n "$sysctl_name" 2>/dev/null)"
    else
        echo "  ⚠ $sysctl_name missing"
    fi
done
if [ -f /redwood/glenv ]; then
    echo "  ✓ Mesa glenv configured"
else
    echo "  ⚠ Mesa glenv missing"
fi
for f in /var/tmp/gl.args /private/var/tmp/gl.args /redwood/gl.args; do
    if [ -f "$f" ] && grep -q "glthread=1" "$f" 2>/dev/null; then
        echo "  ✓ $f: $(cat $f)"
    else
        echo "  ⚠ $f missing or incomplete"
    fi
done

# Check Jailbreak Permissions (82)
echo ""
echo "Jailbreak Permissions (Procursus):"
LDID_BIN="/var/jb/usr/bin/ldid"
[ -x "$LDID_BIN" ] || LDID_BIN="/usr/bin/ldid"

for app in Sileo Zebra; do
    MAIN_BIN="$JB_APPS/$app.app/$app"
    HELPER_BIN="$JB_APPS/$app.app/giveMeRoot"

    if [ -f "$MAIN_BIN" ]; then
        PERM=$(stat -f "%Mp%Lp" "$MAIN_BIN" 2>/dev/null || stat -c "%a" "$MAIN_BIN" 2>/dev/null)
        ENT=$("$LDID_BIN" -e "$MAIN_BIN" 2>/dev/null | grep -E 'platform-application|no-sandbox|skip-library-validation|get-task-allow' | wc -l)
        echo "  $app: perms=$PERM entitlements=$ENT/4"
    else
        echo "  $app: MISSING"
    fi

    if [ -f "$HELPER_BIN" ]; then
        PERM=$(stat -f "%Mp%Lp" "$HELPER_BIN" 2>/dev/null || stat -c "%a" "$HELPER_BIN" 2>/dev/null)
        echo "  $app giveMeRoot: perms=$PERM (expect 4755)"
    else
        echo "  $app giveMeRoot: MISSING"
    fi
done

# Check APT sandbox config
if [ -f "$JB_ROOT/etc/apt/apt.conf.d/20sapphire-sandbox.conf" ]; then
    echo "  APT sandbox config: ✓"
else
    echo "  APT sandbox config: MISSING"
fi

# Check symlinks
echo "  /var/jb -> $(readlink /var/jb 2>/dev/null || echo 'BROKEN')"
echo "  /var -> $(readlink /var 2>/dev/null || echo 'BROKEN')"

echo ""
echo "=== [76] All fixes applied ==="
echo "Reboot device to iOS to activate all changes."
true