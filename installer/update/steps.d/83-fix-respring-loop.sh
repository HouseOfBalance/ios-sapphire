#!/bin/bash
# 83-fix-respring-loop.sh: Eliminate Continuous Respring Loop
# Root causes: GPU fence stall watchdog, tweak injection crashes, Jetsam OOM, CFPreferences corruption
# Architecture: Pure iOS/XNU/launchd - NO Android init.rc

set -e

echo "=== [83] Fixing Continuous Respring Loop ==="

JB_ROOT="/private/var/jb"
SPRINGBOARD_PREFS="/private/var/mobile/Library/Preferences"

# ─────────────────────────────────────────────────────────────────
# 1. CREATE RESPRING MONITOR & SAFE MODE MECHANISM
# ─────────────────────────────────────────────────────────────────
echo "Installing respring monitor daemon..."

cat > /redwood/bin/respring-monitor.sh <<'MONITOR_EOF'
#!/bin/bash
# respring-monitor.sh: Detects SpringBoard crash loop and enables SafeMode
# Runs every 10 seconds via launchd

SAFEMODE_FLAG="/redwood/safemode"
CRASH_LOG="/var/tmp/springboard-crash.log"
LAUNCHD_TWEAK_DIR="/var/jb/usr/lib/TweakInject"

# Count SpringBoard crashes in last 60 seconds
count_recent_crashes() {
    local now=$(date +%s)
    local cutoff=$((now - 60))
    local count=0

    if [ -f "$CRASH_LOG" ]; then
        while IFS= read -r line; do
            # Log format: "timestamp: SpringBoard[pid] exited abnormally: signal"
            local ts=$(echo "$line" | cut -d: -f1)
            if [ "$ts" -ge "$cutoff" ] 2>/dev/null; then
                count=$((count + 1))
            fi
        done < "$CRASH_LOG"
    fi
    echo $count
}

# Log crash from syslog (called by launchd WatchPaths on /var/log/syslog)
log_crash() {
    local msg="$1"
    echo "$(date +%s): $msg" >> "$CRASH_LOG"
    # Keep only last 200 lines
    tail -200 "$CRASH_LOG" > "$CRASH_LOG.tmp" && mv "$CRASH_LOG.tmp" "$CRASH_LOG"
}

# Main monitoring loop
CRASH_COUNT=$(count_recent_crashes)

if [ "$CRASH_COUNT" -ge 2 ]; then
    echo "[RespringMonitor] CRITICAL: $CRASH_COUNT SpringBoard crashes in 60s - enabling SafeMode"
    touch "$SAFEMODE_FLAG"

    # Disable tweak injection for SpringBoard by unloading all tweak plists
    for plist in "$LAUNCHD_TWEAK_DIR"/*.plist; do
        [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null || true
    done

    # Disable GPU pipeline to reduce fence waits
    sysctl -w kern.sweet_fb_pipeline=0 2>/dev/null || true
    sysctl -w kern.sweet_fb_max_inflight=1 2>/dev/null || true

    # Notify user via notification
    /var/jb/usr/bin/sbctl notify "SafeMode Enabled" "SpringBoard crashed repeatedly. Tweaks disabled." 2>/dev/null || true

elif [ "$CRASH_COUNT" -eq 0 ] && [ -f "$SAFEMODE_FLAG" ]; then
    # Auto-exit SafeMode after 5 minutes of stability
    local flag_age=$(($(date +%s) - $(stat -f %m "$SAFEMODE_FLAG" 2>/dev/null || stat -c %Y "$SAFEMODE_FLAG" 2>/dev/null)))
    if [ "$flag_age" -gt 300 ]; then
        echo "[RespringMonitor] Stability restored - exiting SafeMode"
        rm -f "$SAFEMODE_FLAG"

        # Re-enable tweaks
        for plist in "$LAUNCHD_TWEAK_DIR"/*.plist; do
            [ -f "$plist" ] && launchctl load "$plist" 2>/dev/null || true
        done

        # Restore GPU pipeline
        sysctl -w kern.sweet_fb_pipeline=1 2>/dev/null || true
        sysctl -w kern.sweet_fb_max_inflight=3 2>/dev/null || true
    fi
fi
MONITOR_EOF

chmod 755 /redwood/bin/respring-monitor.sh

# Launchd job for respring monitor (every 10 seconds)
cat > /redwood/launchd/com.sapphire.respring-monitor.plist <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sapphire.respring-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/redwood/bin/respring-monitor.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/var/tmp/respring-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>/var/tmp/respring-monitor.log</string>
</dict>
</plist>
PLIST_EOF

# ─────────────────────────────────────────────────────────────────
# 2. DISABLE WATCHDOGS (FrontBoard / BackBoard)
# ─────────────────────────────────────────────────────────────────
echo "Disabling FrontBoard/BackBoard watchdogs..."

# SpringBoard preferences - disable watchdogs
mkdir -p "$SPRINGBOARD_PREFS"
cat > "$SPRINGBOARD_PREFS/com.apple.springboard.plist" <<'SB_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BKNoWatchdogs</key>
    <true/>
    <key>FBLaunchWatchdogTimeout</key>
    <integer>300</integer>
    <key>BKWatchdogTimeout</key>
    <integer>300</integer>
    <key>SBDisableWatchdog</key>
    <true/>
    <key>SBAllowWatchdogDuringLaunch</key>
    <false/>
</dict>
</plist>
SB_EOF

chown 501:501 "$SPRINGBOARD_PREFS/com.apple.springboard.plist"
chmod 600 "$SPRINGBOARD_PREFS/com.apple.springboard.plist"

# backboardd preferences
cat > "$SPRINGBOARD_PREFS/com.apple.backboardd.plist" <<'BB_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BKNoWatchdogs</key>
    <true/>
    <key>BKWatchdogTimeout</key>
    <integer>300</integer>
</dict>
</plist>
BB_EOF

chown 501:501 "$SPRINGBOARD_PREFS/com.apple.backboardd.plist"
chmod 600 "$SPRINGBOARD_PREFS/com.apple.backboardd.plist"

# ─────────────────────────────────────────────────────────────────
# 3. INCREASE JETSAM MEMORY LIMITS FOR SPRINGBOARD & BACKBOARD
# ─────────────────────────────────────────────────────────────────
echo "Increasing Jetsam memory limits..."

# Create jetsam properties override
mkdir -p /private/var/db
cat > /private/var/db/jetsam_properties_override.plist <<'JETSAM_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>SpringBoard</key>
    <dict>
        <key>memorylimit</key>
        <integer>536870912</integer>  <!-- 512 MB -->
        <key>priority</key>
        <integer>30</integer>
    </dict>
    <key>backboardd</key>
    <dict>
        <key>memorylimit</key>
        <integer>268435456</integer>  <!-- 256 MB -->
        <key>priority</key>
        <integer>30</integer>
    </dict>
    <key>RenderServer</key>
    <dict>
        <key>memorylimit</key>
        <integer>268435456</integer>  <!-- 256 MB -->
        <key>priority</key>
        <integer>30</integer>
    </dict>
    <key>AppleCLCD</key>
    <dict>
        <key>memorylimit</key>
        <integer>134217728</integer>  <!-- 128 MB -->
        <key>priority</key>
        <integer>35</integer>
    </dict>
</dict>
</plist>
JETSAM_EOF

# Sysctl for jetsam (if available on this XNU build)
sysctl -w kern.jetsam_task_limit=536870912 2>/dev/null || true
sysctl -w kern.memorystatus_priority_offset=30 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────
# 4. FIX CFPREFERENCES CORRUPTION (PERMISSIONS & XML VALIDITY)
# ─────────────────────────────────────────────────────────────────
echo "Fixing CFPreferences permissions and validity..."

# Ensure mobile owns all preference files
chown -R 501:501 "$SPRINGBOARD_PREFS" 2>/dev/null || true
chmod -R 600 "$SPRINGBOARD_PREFS"/*.plist 2>/dev/null || true

# Validate and repair XML plists
for plist in "$SPRINGBOARD_PREFS"/*.plist; do
    if [ -f "$plist" ]; then
        if ! plutil -lint "$plist" >/dev/null 2>&1; then
            echo "  Repairing corrupted plist: $(basename "$plist")"
            # Backup and recreate minimal valid plist
            cp "$plist" "$plist.corrupted.$(date +%s)"
            echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$plist"
            chown 501:501 "$plist"
            chmod 600 "$plist"
        fi
    fi
done

# Ensure critical plists exist with valid content
for critical_plist in \
    "com.apple.springboard.plist" \
    "com.apple.backboardd.plist" \
    "com.apple.frontboard.plist" \
    "com.apple.Accessibility.plist" \
    "com.apple.controlcenter.plist"; do
    if [ ! -f "$SPRINGBOARD_PREFS/$critical_plist" ]; then
        echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$SPRINGBOARD_PREFS/$critical_plist"
        chown 501:501 "$SPRINGBOARD_PREFS/$critical_plist"
        chmod 600 "$SPRINGBOARD_PREFS/$critical_plist"
    fi
done

# ─────────────────────────────────────────────────────────────────
# 5. GPU FENCE TIMEOUT MITIGATION (eagl.c adaptive sync)
# ─────────────────────────────────────────────────────────────────
echo "Configuring GPU fence timeout mitigation..."

# Boot args for adaptive fence (already in 58-sapphire-boot-args.sh but ensure)
cat > /redwood/boot.d/83-gpu-fence-mitigation.sh <<'FENCE_EOF'
#!/bin/bash
# Reduce GPU fence wait timeout to prevent watchdog trigger
sysctl -w kern.sweet_gpu_fence_timeout_ms=2000 2>/dev/null || true
sysctl -w kern.sweet_gpu_fence_poll_us=50 2>/dev/null || true
# Enable async flush to prevent blocking
sysctl -w kern.sweet_gpu_async_flush=1 2>/dev/null || true
FENCE_EOF
chmod 755 /redwood/boot.d/83-gpu-fence-mitigation.sh

# ─────────────────────────────────────────────────────────────────
# 6. TWEAK CRASH PROTECTION (ElleKit selector validation)
# ─────────────────────────────────────────────────────────────────
echo "Installing tweak crash protection..."

cat > /redwood/bin/tweak-guard.sh <<'TWEAK_EOF'
#!/bin/bash
# tweak-guard.sh: Validates ElleKit tweak selectors before injection
# Prevents bad hooks from crashing SpringBoard

TWEAK_DIR="/var/jb/usr/lib/TweakInject"
VALIDATION_LOG="/var/tmp/tweak-validation.log"

validate_tweak() {
    local dylib="$1"
    local name=$(basename "$dylib")

    # Check for required entry points
    if ! nm "$dylib" 2>/dev/null | grep -q "_MSHookFunction\|__attribute__((constructor))"; then
        echo "[$(date)] SKIP: $name - no valid hook entry point" >> "$VALIDATION_LOG"
        return 1
    fi

    # Check for known bad selectors on iOS 16.7.16
    local bad_selectors=(
        "_UIKBRenderFactorySharedInstance"
        "_UIKeyboardLayoutStarProvider"
        "_CBSDisplayServicesSetBrightness"
        "CADisplayLink.*private"
    )

    for sel in "${bad_selectors[@]}"; do
        if strings "$dylib" 2>/dev/null | grep -q "$sel"; then
            echo "[$(date)] WARN: $name references potentially unstable selector: $sel" >> "$VALIDATION_LOG"
        fi
    done

    echo "[$(date)] OK: $name passed validation" >> "$VALIDATION_LOG"
    return 0
}

# Validate all tweaks
for dylib in "$TWEAK_DIR"/*.dylib; do
    [ -f "$dylib" ] && validate_tweak "$dylib"
done

# Move invalid tweaks to quarantine
QUARANTINE="$TWEAK_DIR/.quarantine"
mkdir -p "$QUARANTINE"
for dylib in "$TWEAK_DIR"/*.dylib; do
    name=$(basename "$dylib")
    if ! validate_tweak "$dylib" >/dev/null 2>&1; then
        mv "$dylib" "$QUARANTINE/" 2>/dev/null
        mv "${dylib%.dylib}.plist" "$QUARANTINE/" 2>/dev/null
        echo "[$(date)] QUARANTINED: $name" >> "$VALIDATION_LOG"
    fi
done
TWEAK_EOF

chmod 755 /redwood/bin/tweak-guard.sh

# Run validation at boot
cat > /redwood/boot.d/83-tweak-validation.sh <<'TV_EOF'
#!/bin/bash
/redwood/bin/tweak-guard.sh &
TV_EOF
chmod 755 /redwood/boot.d/83-tweak-validation.sh

# ─────────────────────────────────────────────────────────────────
# 7. VERIFICATION
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="

echo "Respring monitor: $( [ -f /redwood/bin/respring-monitor.sh ] && echo '✓ installed' || echo '✗ missing' )"
echo "Launchd monitor: $( [ -f /redwood/launchd/com.sapphire.respring-monitor.plist ] && echo '✓ installed' || echo '✗ missing' )"
echo "SafeMode flag: $( [ -f /redwood/safemode ] && echo 'ACTIVE' || echo 'inactive' )"
echo "Watchdog disabled (SB): $( grep -q 'BKNoWatchdogs.*true' "$SPRINGBOARD_PREFS/com.apple.springboard.plist" && echo '✓' || echo '✗' )"
echo "Watchdog disabled (BB): $( grep -q 'BKNoWatchdogs.*true' "$SPRINGBOARD_PREFS/com.apple.backboardd.plist" && echo '✓' || echo '✗' )"
echo "Jetsam override: $( [ -f /private/var/db/jetsam_properties_override.plist ] && echo '✓ installed' || echo '✗ missing' )"
echo "Prefs ownership: $( stat -f "%Su" "$SPRINGBOARD_PREFS" 2>/dev/null || echo 'unknown' )"
echo "Prefs perms: $( stat -f "%Mp%Lp" "$SPRINGBOARD_PREFS/com.apple.springboard.plist" 2>/dev/null || echo 'unknown' )"

echo ""
echo "=== [83] Respring loop fix complete ==="
echo "Next: Reboot to iOS. Monitor /var/tmp/respring-monitor.log for activity."
true