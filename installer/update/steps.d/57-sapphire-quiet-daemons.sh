# Silence/disable background CPU-hogging and crashing daemons
# FIXED: Removed critical daemons that backboardd/installcoordinat depend on
# CRITICAL DAEMONS (MUST NOT DISABLE):
#   com.apple.containermanagerd      - system container URL (backboardd crash if missing)
#   com.apple.cfprefsd.xpc.daemon    - preferences system
#   com.apple.securityd              - security framework
#   com.apple.trustd                 - trust cache validation
#   com.apple.locationd              - location services (SpringBoard needs)
#   com.apple.geod                   - geod daemon
#   com.apple.wifid                  - WiFi daemon
#   com.apple.bluetoothd             - Bluetooth daemon
#   com.apple.mavrouterd             - MAV router (modem IPC)
#   com.apple.pcscd                  - smart card daemon
#   com.apple.networking.wifid       - WiFi networking
#   com.apple.networking.wifip2pd    - WiFi P2P
#   com.apple.nehelper               - network extension helper
#   com.apple.networkd               - network daemon
#   com.apple.apsd                   - push notification daemon
#   com.apple.pushd                  - push daemon
#   com.apple.accountsd              - accounts daemon
#   com.apple.icloud.fmfd            - Find My daemon
#   com.apple.findmydeviced          - Find My device
#   com.apple.passd                  - PassKit daemon
#   com.apple.paymentd               - Payment daemon
#   com.apple.commerce               - App Store commerce
#   com.apple.mobileassetd           - Mobile asset daemon
#   com.apple.appstored              - App Store daemon
#   com.apple.itunesstored           - iTunes Store daemon
#   com.apple.coresymbolicationd     - crash symbolication
#   com.apple.coreduetd              - CoreDuet (activity tracking)
#   com.apple.coreduetd.osx          - CoreDuet macOS
#   com.apple.spotlight              - Spotlight indexer
#   com.apple.metadata.mds           - metadata server
#   com.apple.metadata.mdwrite       - metadata writer

P=/redwood/bin/plistop
C=/System/Library/xpc/launchd.plist
B=/var/root/launchd.plist.pre-quiet

# ONLY non-essential background daemons safe to disable
JOBS="com.apple.parsecd com.apple.cdpd com.apple.searchpartyd com.apple.biomesyncd com.apple.duetexpertd com.apple.parsec-fbf \
      com.apple.atc com.apple.askpermissiond com.apple.managedsettingsd \
      com.apple.cloudpaird com.apple.magicswitchd com.apple.dasd \
      com.apple.diagnosticd com.apple.syslogd com.apple.reportcrash \
      com.apple.routinehubd com.apple.sirid com.apple.assistantd com.apple.virtualbuttond"

# First, RESTORE launchd.plist from backup if it exists
if [ -f "$B" ]; then
    echo "Restoring launchd.plist from backup..."
    cp -p "$B" "$C"
fi

# Then disable only the safe jobs
if [ -f "$C" ] && [ -x "$P" ]; then
    set --
    for j in $JOBS; do
        set -- "$@" del-each LaunchDaemons Label "$j"
    done
    "$P" "$C" "$@" || true
fi

L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl
for j in $JOBS; do
	"$L" disable "system/$j" 2>/dev/null || true
	"$L" bootout "system/$j" 2>/dev/null || true
done

# Set critical UI processes to high priority (renice to -15)
for p in SpringBoard backboardd WindowServer mediaserverd locationd; do
	pgrep -x "$p" | while read pid; do
		renice -15 -p "$pid" 2>/dev/null || true
	done
done

# Pin critical UI processes to P-cores (cores 0-3) via taskpolicy
# SpringBoard + backboardd render threads -> cores 0-1 (strongest)
# WindowServer + mediaserverd -> cores 0-3
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

# Disable CoreAnimation debug overlays
defaults write com.apple.CoreAnimation CA_DEBUG_TRANSPARENT 0 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_DISABLE_BLUR 1 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_HALFRES_BACKDROP 1 2>/dev/null || true

true