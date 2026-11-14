# Silence/disable background CPU-hogging and crashing daemons
# 0339/0342: Extended list for 120fps fluidity - disable all non-essential background daemons
P=/redwood/bin/plistop
C=/System/Library/xpc/launchd.plist
B=/var/root/launchd.plist.pre-quiet
JOBS="com.apple.parsecd com.apple.cdpd com.apple.searchpartyd com.apple.biomesyncd com.apple.duetexpertd com.apple.parsec-fbf \
      com.apple.locationd com.apple.geod com.apple.wifid com.apple.bluetoothd com.apple.mediaremoted \
      com.apple.cfprefsd.xpc.daemon com.apple.securityd com.apple.trustd com.apple.cloudpaird \
      com.apple.atc com.apple.askpermissiond com.apple.managedsettingsd com.apple.containermanagerd \
      com.apple.nehelper com.apple.networkd com.apple.networking.wifid com.apple.networking.wifip2pd \
      com.apple.apsd com.apple.pushd com.apple.mavrouterd com.apple.pcscd \
      com.apple.routinehubd com.apple.sirid com.apple.assistantd com.apple.virtualbuttond \
      com.apple.coresymbolicationd com.apple.coreduetd com.apple.coreduetd.osx \
      com.apple.diagnosticd com.apple.syslogd com.apple.reportcrash \
      com.apple.mobileassetd com.apple.appstored com.apple.itunesstored \
      com.apple.accountsd com.apple.icloud.fmfd com.apple.findmydeviced \
      com.apple.passd com.apple.paymentd com.apple.commerce \
      com.apple.spotlight com.apple.metadata.mds com.apple.metadata.mdwrite"

if [ -f "$C" ] && [ -x "$P" ]; then
	if [ -f "$B" ] || cp -p "$C" "$B"; then
		set --
		for j in $JOBS; do
			set -- "$@" del-each LaunchDaemons Label "$j"
		done
		"$P" "$C" "$@" || true
	fi
fi

L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl
for j in $JOBS; do
	"$L" disable "system/$j" 2>/dev/null || true
	"$L" bootout "system/$j" 2>/dev/null || true
done

# 0339: Set critical UI processes to high priority (renice to -15)
for p in SpringBoard backboardd WindowServer mediaserverd locationd; do
	pgrep -x "$p" | while read pid; do
		renice -15 -p "$pid" 2>/dev/null || true
	done
done

# 0339: Pin critical UI processes to P-cores (cores 0-3) via taskpolicy
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

# 0342: Disable CoreAnimation debug overlays
defaults write com.apple.CoreAnimation CA_DEBUG_TRANSPARENT 0 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_DISABLE_BLUR 1 2>/dev/null || true
defaults write com.apple.CoreAnimation CA_HALFRES_BACKDROP 1 2>/dev/null || true

true