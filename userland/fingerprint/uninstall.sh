#!/bin/bash
# uninstall.sh [--restore-backup] [PHONE]: fingerprint unlock off the phone, from WSL.
#   stops com.sapphire.fpd, takes its job out of launchd's cache (fpd-launchd.py remove: every other job is
#   kept as it is now), removes both tweaks, the Huella app, /redwood/bin/fpd (+ fpctl ...) and
#   /redwood/share/fpd, restarts SpringBoard.
#   --restore-backup: puts back launchd.plist.pre-fpd (the cache from before the first install) instead of
#   editing the current one -- only if no other job was added to the cache since.
# /var/root/fp (the user's calibration and template copies) and /var/root/fpload, fpsave are never touched.
set -e
cd "$(dirname "$0")"
restore=0
if [ "$1" = --restore-backup ]; then restore=1; shift; fi
P=${1:-root@192.168.7.2}
O="-o ConnectTimeout=6 -i $HOME/.ssh/sapphire_phone"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

ssh $O $P /var/jb/bin/bash -s <<'EOF'
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
launchctl bootout system/com.sapphire.fpd 2>/dev/null || launchctl remove com.sapphire.fpd 2>/dev/null || true
killall fpd 2>/dev/null || true
rm -f /var/jb/usr/lib/TweakInject/SapphireFingerprint.dylib* /var/jb/usr/lib/TweakInject/SapphireFingerprint.plist
rm -f /var/jb/usr/lib/TweakInject/SapphireFingerprintSettings.dylib* /var/jb/usr/lib/TweakInject/SapphireFingerprintSettings.plist
h=$(ls -d /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper 2>/dev/null | head -1)
[ -n "$h" ] && "$h" uninstall com.sapphire.fingerprint 2>/dev/null && echo "Huella app removed (TrollStore)"
if [ -d /Applications/Huella.app ]; then uicache -u /Applications/Huella.app 2>/dev/null; rm -rf /Applications/Huella.app; echo "Huella app removed (/Applications)"; fi
rm -f /var/run/fpd.sock
EOF

# Remove boot.d script and restore launchd cache if needed
ssh $O $P rm -f /redwood/boot.d/95-fpd.sh

if [ $restore = 1 ]; then
	ssh $O $P /var/jb/bin/bash -s <<'EOF'
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
L=/System/Library/xpc/launchd.plist
[ -f $L.pre-fpd ] || { echo "no $L.pre-fpd"; exit 1; }
/var/jb/bin/cp -p $L.pre-fpd $L.fpd-new && /var/jb/bin/mv -f $L.fpd-new $L && ls -l $L && echo "launchd cache restored from pre-fpd"
EOF
fi

ssh $O $P /var/jb/bin/bash -s <<'EOF'
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
rm -f /redwood/bin/fpd /redwood/bin/fpd.prev /redwood/bin/fpload /redwood/bin/fpsave /redwood/bin/fpctl
rm -rf /redwood/share/fpd
killall -9 SpringBoard 2>/dev/null || true
echo "uninstalled (SpringBoard restarted without the tweak)"
EOF
