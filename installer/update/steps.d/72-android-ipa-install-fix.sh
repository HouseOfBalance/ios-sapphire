#!/bin/bash
# 72-android-ipa-install-fix.sh: Fix Android IPA Installs Missing After Reboot
# Root causes:
# 1. sapphire-ipa-install.sh runs but doesn't guarantee uicache -a completes before SpringBoard reads icon cache
# 2. Apps may lack proper code signature (ldid -S) for SpringBoard to display
# 3. IPA installation via TrollStore helper may not register with lsd (LaunchServices)
# 4. IPA entry cleanup needs to be more robust
# 5. Hardcoded TrollStore helper path - needs to search multiple locations
# 6. SpringBoard wait loop blocking for up to 5 minutes

set -e

echo "=== [72] Fixing Android IPA Install Registration ==="

# 1. Enhance sapphire-ipa-install.sh with proper registration steps
cat > /redwood/bin/sapphire-ipa-install.sh <<'EOF'
#!/var/jb/bin/bash
# Enhanced IPA installer from Android inbox
# Ensures: signature, lsd registration, uicache, SpringBoard notification
# Supports multiple TrollStore helper locations

export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
CAT=/redwood/bin/sapphire-inboxcat
STATE=/var/root/.sapphire-ipas
LOG=/var/root/sapphire-ipa.log
W=/var/tmp/sapphire-ipa
LOCK=/var/root/.sapphire-ipa.lock

log() { echo "$(date '+%F %T') $*" >> $LOG; echo "sapphire-ipa: $*" > /dev/console 2>/dev/null; }

# Prevent concurrent runs
exec 9>"$LOCK"
flock -n 9 || { log "Another instance running, exiting"; exit 0; }

# Find TrollStore helper - check multiple possible locations
find_trollstore_helper() {
    # Common locations
    local paths=(
        "/var/jb/Applications/TrollStorePersistenceHelper.app/trollstorehelper"
        "/var/jb/Applications/TrollStore.app/trollstorehelper"
    )

    # Also check /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper
    for container in /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper; do
        if [ -x "$container" ]; then
            paths+=("$container")
        fi
    done

    for path in "${paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

HELPER=$(find_trollstore_helper)
[ -x "$CAT" ] && [ -x "$HELPER" ] || { log "Missing inboxcat or trollstorehelper"; exit 0; }
log "Using TrollStore helper: $HELPER"

# Wait for SpringBoard and calm boot (at least 90s after boot) - with timeout
boot_time=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
if [ -z "$boot_time" ]; then
    boot_time=$(date +%s)
fi
now=$(date +%s)
wait_needed=$(( 90 - (now - boot_time) ))
if [ $wait_needed -gt 0 ]; then
    log "Waiting ${wait_needed}s for calm boot (90s after boot)"
    sleep $wait_needed
fi

# Wait for SpringBoard with max 30s timeout (6 x 5s)
for i in $(seq 1 6); do
    killall -0 SpringBoard 2>/dev/null && break
    sleep 5
done

# Final check - if SpringBoard still not up, exit gracefully
killall -0 SpringBoard 2>/dev/null || { log "SpringBoard not running after wait, exiting"; exit 0; }

S=$($CAT start) || { log "Failed to start inbox read"; exit 0; }
hdr=$(mktemp)
$CAT "$S" 4096 > "$hdr" 2>/dev/null || { rm -f "$hdr"; log "Failed to read inbox header"; exit 0; }
[ "$(head -c 8 "$hdr")" = SPHIPAQ1 ] || { rm -f "$hdr"; log "Invalid inbox header"; exit 0; }

le() { od -An -t u$2 -j $1 -N $2 "$hdr" | tr -d ' '; }
count=$(le 12 4)
touch $STATE

for i in $(seq 0 $(( count - 1 ))); do
    e=$(( 24 + 256 * i ))
    name=$(dd if="$hdr" bs=1 skip=$(( e + 56 )) count=192 2>/dev/null | tr -d '\0')
    case "$name" in *.ipa|*.IPA|*.tipa) ;; *) continue ;; esac
    off=$(le $e 8); len=$(le $(( e + 8 )) 8)
    sha=$(od -An -tx1 -j $(( e + 16 )) -N 32 "$hdr" | tr -d ' \n')
    grep -q "^$sha " $STATE && continue

    rm -rf $W; mkdir -p $W
    f="$W/app.ipa"
    if ! $CAT $(( S + off )) "$len" > "$f"; then
        log "$name: the inbox could not be read"; continue
    fi
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ "$got" != "$sha" ]; then
        echo "$sha failed $name $(date +%s)" >> $STATE; log "$name: sha256 mismatch"; continue
    fi

    # Install via TrollStore helper (try normal, then force for unsigned/fakesigned)
    if $HELPER install "$f" >> $LOG 2>&1 || $HELPER install "$f" force >> $LOG 2>&1; then
        echo "$sha installed $name $(date +%s)" >> $STATE; log "$name: installed"

        # CRITICAL: Find the installed app bundle and ensure it's properly signed
        # TrollStore installs to /private/var/containers/Bundle/Application/<UUID>/
        APP_PATH=$(find /private/var/containers/Bundle/Application -name "*.app" -newer "$f" 2>/dev/null | head -1)
        if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
            # Ensure all binaries in the app are signed
            find "$APP_PATH" -type f -perm +111 -exec /var/jb/usr/bin/ldid -S {} \; 2>/dev/null || true
            # Also sign the main executable
            BINARY=$(basename "$APP_PATH" .app)
            if [ -f "$APP_PATH/$BINARY" ]; then
                /var/jb/usr/bin/ldid -S "$APP_PATH/$BINARY" 2>/dev/null || true
            fi
            log "$name: signed binaries in $APP_PATH"
        fi

        # Register with LaunchServices (lsd) via uicache for this specific app
        if [ -n "$APP_PATH" ]; then
            /var/jb/usr/bin/uicache -p "$APP_PATH" >> $LOG 2>&1 &
        fi
    else
        echo "$sha failed $name $(date +%s)" >> $STATE; log "$name: trollstorehelper failed ($?)"
    fi
    rm -rf $W
done

rm -f "$hdr"

# Global uicache to ensure all icons are registered
/var/jb/usr/bin/uicache -a >/dev/null 2>&1 &
# Wait briefly for uicache to complete
sleep 2

# Notify SpringBoard to refresh icon cache
killall -SIGUSR1 SpringBoard 2>/dev/null || true

log "IPA install cycle complete"
exit 0
EOF
chmod 755 /redwood/bin/sapphire-ipa-install.sh

# 2. Create a more robust launchd job that runs periodically
cat > /redwood/launchd/com.sapphire.ipa-install.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sapphire.ipa-install</string>
    <key>ProgramArguments</key>
    <array>
        <string>/redwood/bin/sapphire-ipa-install.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/tmp/sapphire-ipa-install.log</string>
    <key>StandardErrorPath</key>
    <string>/var/tmp/sapphire-ipa-install.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

# 3. Boot.d script to load the job
cat > /redwood/boot.d/72-ipa-install.sh <<'EOF'
#!/bin/bash
# Load IPA installer job
launchctl list com.sapphire.ipa-install >/dev/null 2>&1 || launchctl load /redwood/launchd/com.sapphire.ipa-install.plist
EOF
chmod 755 /redwood/boot.d/72-ipa-install.sh

# 4. Also fix the simpler 60-sapphire-ipa.sh to use the enhanced script
cat > /redwood/boot.d/60-sapphire-ipa.sh <<'EOF'
#!/bin/bash
# Run IPA installer once at boot (the launchd job handles periodic runs)
/redwood/bin/sapphire-ipa-install.sh &
EOF
chmod 755 /redwood/boot.d/60-sapphire-ipa.sh

# 5. Add CommCenter ccstart boot script
cat > /redwood/boot.d/77-commcenter-ccstart.sh <<'EOF'
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
EOF
chmod 755 /redwood/boot.d/77-commcenter-ccstart.sh

echo "=== [72] Android IPA install fix applied ==="
true