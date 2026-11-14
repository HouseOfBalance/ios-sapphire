# Silence/disable background CPU-hogging and crashing daemons
# FIXED: Re-enable all critical daemons, clear launchd persistent disabled database,
# and ensure containermanagerd and backboardd are alive.

P=/redwood/bin/plistop
C=/System/Library/xpc/launchd.plist
B=/var/root/launchd.plist.pre-quiet

# Critical daemons that MUST be enabled
CRITICAL_DAEMONS="com.apple.containermanagerd com.apple.cfprefsd.xpc.daemon com.apple.securityd com.apple.trustd \
                  com.apple.locationd com.apple.geod com.apple.wifid com.apple.bluetoothd com.apple.mavrouterd \
                  com.apple.pcscd com.apple.networking.wifid com.apple.networking.wifip2pd com.apple.nehelper \
                  com.apple.networkd com.apple.apsd com.apple.pushd com.apple.accountsd com.apple.icloud.fmfd \
                  com.apple.findmydeviced com.apple.passd com.apple.paymentd com.apple.commerce \
                  com.apple.mobileassetd com.apple.appstored com.apple.itunesstored com.apple.coresymbolicationd \
                  com.apple.coreduetd com.apple.coreduetd.osx com.apple.spotlight com.apple.metadata.mds com.apple.metadata.mdwrite"

# ONLY non-essential background daemons safe to disable
SAFE_JOBS="com.apple.parsecd com.apple.cdpd com.apple.searchpartyd com.apple.biomesyncd com.apple.duetexpertd com.apple.parsec-fbf \
           com.apple.atc com.apple.askpermissiond com.apple.managedsettingsd \
           com.apple.cloudpaird com.apple.magicswitchd com.apple.dasd \
           com.apple.diagnosticd com.apple.syslogd com.apple.reportcrash \
           com.apple.routinehubd com.apple.sirid com.apple.assistantd com.apple.virtualbuttond"

L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl

# 1. Clear launchd persistent disabled database that was corrupted by v0.4.0
rm -f /var/db/com.apple.xpc.launchd/disabled* /private/var/db/com.apple.xpc.launchd/disabled* 2>/dev/null || true

# 2. First, RESTORE launchd.plist from backup if it exists
if [ -f "$B" ]; then
    echo "Restoring launchd.plist from backup..."
    cp -p "$B" "$C"
fi

# 3. Explicitly RE-ENABLE all critical daemons
for d in $CRITICAL_DAEMONS; do
    "$L" enable "system/$d" 2>/dev/null || true
done

# 4. Disable only the safe jobs in launchd.plist using plistop
if [ -f "$C" ] && [ -x "$P" ]; then
    set --
    for j in $SAFE_JOBS; do
        set -- "$@" del-each LaunchDaemons Label "$j"
    done
    "$P" "$C" "$@" || true
fi

# 5. Disable and bootout safe jobs in running launchd
for j in $SAFE_JOBS; do
    "$L" disable "system/$j" 2>/dev/null || true
    "$L" bootout "system/$j" 2>/dev/null || true
done

# 6. Kickstart containermanagerd immediately so it is running for backboardd
"$L" bootstrap system /System/Library/LaunchDaemons/com.apple.containermanagerd.plist 2>/dev/null || true
"$L" kickstart -k system/com.apple.containermanagerd 2>/dev/null || true

# 7. Set critical UI processes to high priority (renice to -15)
for p in SpringBoard backboardd WindowServer mediaserverd locationd; do
    pgrep -x "$p" | while read pid; do
        renice -15 -p "$pid" 2>/dev/null || true
    done
done

# 8. Pin critical UI processes to P-cores (cores 0-3) via taskpolicy
for p in SpringBoard backboardd; do
    pgrep -x "$p" | while read pid; do
        taskpolicy -p "$pid" 0x3 2>/dev/null || true  # cores 0-1
    done
done
for p in WindowServer mediaserverd; do
    pgrep -x "$p" | while read pid; do
        taskpolicy -p "$pid" 0xF 2>/dev/null || true  # cores 0-3
    done
done

# 9. Disable CoreAnimation debug overlays
defaults write com.apple.CoreAnimation CA_DEBUG_TRANSPARENT 0 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_DISABLE_BLUR 1 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_HALFRES_BACKDROP 1 2>/dev/null || true

# 10. Restart backboardd now that containermanagerd is unblocked and running!
sleep 1
killall -9 backboardd 2>/dev/null || true

true
