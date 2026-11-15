#!/bin/bash
# install.sh [PHONE]: fingerprint unlock onto the phone (root@192.168.7.2, key ~/.ssh/sapphire_phone), from WSL.
#   /redwood/bin/{fpd,fpload,fpsave,fpctl}, /redwood/share/fpd/com.sapphire.fpd.plist
#   /var/jb/usr/lib/TweakInject/SapphireFingerprint.{dylib,plist} (loaded by the next SpringBoard)
#   /var/jb/usr/lib/TweakInject/SapphireFingerprintSettings.{dylib,plist} (the Settings row, next Settings launch)
#   the Huella app (install-app.sh: TrollStore's trollstorehelper, else /Applications + uicache)
#   launchd's cache /System/Library/xpc/launchd.plist + job com.sapphire.fpd (fpd-launchd.py add); the cache
#   before the first install stays on the phone as launchd.plist.pre-fpd, and every cache this script replaces
#   is also kept in ~/ios-build/launchd-backups/ here.
# fpd is not (re)started: fptest.sh start (or a reboot) starts it, fptest.sh respring loads the tweak.
# An existing install is brought up to date with update.sh instead (no launchd cache change).
# Rollback: uninstall.sh.
set -e
cd "$(dirname "$0")"
P=${1:-root@192.168.7.2}
O="-o ConnectTimeout=6 -i $HOME/.ssh/sapphire_phone"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
bash build.sh "$out" > /dev/null
ssh $O $P /var/jb/bin/bash -s <<'EOF'
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
mkdir -p /redwood/bin /redwood/share/fpd /var/jb/usr/lib/TweakInject
[ -d /var/root/fp ] || echo "WARNING: /var/root/fp missing (fpd will do nothing)"
L=/System/Library/xpc/launchd.plist
[ -f $L.pre-fpd ] || /var/jb/bin/cp -p $L $L.pre-fpd
ls -l $L $L.pre-fpd
EOF
scp -q $O "$out/fpd" "$out/fpload" "$out/fpsave" "$out/fpctl" $P:/redwood/bin/
scp -q $O "$out/com.sapphire.fpd.plist" $P:/redwood/share/fpd/
scp -q $O "$out/SapphireFingerprint.dylib" "$out/SapphireFingerprint.plist" "$out/SapphireFingerprintSettings.dylib" 	"$out/SapphireFingerprintSettings.plist" $P:/var/jb/usr/lib/TweakInject/

# Deploy 95-fpd.sh boot script (avoids launchd cache platform binary panic)
scp -q $O "$(dirname "$0")/95-fpd.sh" $P:/redwood/boot.d/95-fpd.sh
ssh $O $P /var/jb/bin/bash -s <<'EOF'
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
mkdir -p /redwood/boot.d
chmod 755 /redwood/boot.d/95-fpd.sh
chown root:wheel /redwood/bin/fpd /redwood/bin/fpload /redwood/bin/fpsave /redwood/bin/fpctl /redwood/share/fpd/com.sapphire.fpd.plist /redwood/boot.d/95-fpd.sh
chmod 755 /redwood/bin/fpd /redwood/bin/fpload /redwood/bin/fpsave /redwood/bin/fpctl
chmod 644 /redwood/share/fpd/com.sapphire.fpd.plist /var/jb/usr/lib/TweakInject/SapphireFingerprint*.plist
chmod 755 /var/jb/usr/lib/TweakInject/SapphireFingerprint*.dylib
ls -l /redwood/bin/fpd /var/jb/usr/lib/TweakInject/SapphireFingerprint.* /redwood/boot.d/95-fpd.sh
echo "installed; start: fptest.sh start, tweak: fptest.sh respring"
EOF
bash install-app.sh "$out/Huella.ipa" "$P"
