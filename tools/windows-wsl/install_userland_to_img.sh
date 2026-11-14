#!/bin/bash
set -euo pipefail
IMG="${IMG:-$HOME/work/out/ios16-root.img}"
MNT="${MNT:-/mnt/ios_build}"
REPO="${REPO:-$HOME/ios-sapphire}"
JB_ROOT="${JB_ROOT:-$HOME/work/jb-build/root/var/jb}"
LLVM="${LLVM:-/usr/lib/llvm-18/bin}"
SDK="${SDK:-$HOME/work/sdks/theos-sdks/iPhoneOS16.5.sdk}"
LDID="${LDID:-$HOME/tools-dl/ldid/ldid}"

# Build rtcd
mkdir -p "$REPO/userland/obj"
"$LLVM/clang" -target arm64-apple-ios15.0 -isysroot "$SDK" -fuse-ld=lld -O2 -Wall \
    -o "$REPO/userland/obj/rtcd" "$REPO/userland/rtcd/rtcd.c"

# Ad-hoc sign all userland binaries and dylibs so SWEET AMFI marks them as platform binaries
"$LDID" -S"$REPO/userland/rtcd/ent.xml" "$REPO/userland/obj/rtcd"
"$LDID" -S"$REPO/userland/telephony/ctdial.entitlements" "$REPO/userland/obj/ctdial"
for bin in bbstart ccstart qmitool pdpnet; do
    "$LDID" -S "$REPO/userland/obj/$bin"
done
for dylib in libredwood-gl.dylib libredwood-glload.dylib ccbridge.dylib libsapphire-fakebb.dylib; do
    "$LDID" -S "$REPO/userland/obj/$dylib"
done
"$LDID" -S "$HOME/work/mesa-ios/out/libOSMesa.8.dylib"
"$LDID" -S "$REPO/metal/out/SapphireMetal.bundle/SapphireMetal"
"$LDID" -S "$REPO/userland/obj/RedwoodAudio.driver/RedwoodAudio"

# Generate SSH keypair if not present
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
[ -f "$HOME/.ssh/sapphire_phone" ] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/sapphire_phone"

# Load hfsplus module if needed
grep -qw hfsplus /proc/filesystems || sudo insmod "$HOME/modules/hfsplus.ko"
sudo mkdir -p "$MNT"
sudo mountpoint -q "$MNT" && sudo umount "$MNT"
sudo mount -t hfsplus -o loop,force "$IMG" "$MNT"
trap 'sudo mountpoint -q "$MNT" && sudo umount "$MNT"' EXIT

test -d "$MNT/System/Library"

echo "=== 1. /redwood ==="
sudo mkdir -p "$MNT/redwood/lib" "$MNT/redwood/bin" "$MNT/redwood/share/rtcd"
sudo cp "$HOME/work/mesa-ios/out/libOSMesa.8.dylib" "$MNT/redwood/lib/"
sudo cp "$REPO/userland/obj/libredwood-gl.dylib" "$MNT/redwood/lib/"
sudo cp "$REPO/userland/obj/libredwood-glload.dylib" "$MNT/redwood/lib/"
sudo cp "$REPO/userland/obj/ccbridge.dylib" "$MNT/redwood/lib/"
sudo cp "$REPO/userland/obj/libsapphire-fakebb.dylib" "$MNT/redwood/lib/"
sudo cp "$REPO/userland/obj/ccstart" "$REPO/userland/obj/bbstart" "$REPO/userland/obj/rtcd" "$MNT/redwood/bin/"
sudo cp "$REPO/userland/rtcd/com.sapphire.rtcd.plist" "$MNT/redwood/share/rtcd/"
sudo chown -R 0:0 "$MNT/redwood"
sudo chmod 755 "$MNT/redwood" "$MNT/redwood/lib" "$MNT/redwood/bin" "$MNT/redwood/lib/"*.dylib "$MNT/redwood/bin/"*

echo "=== 2. SapphireMetal.bundle ==="
sudo rm -rf "$MNT/System/Library/Extensions/SapphireMetal.bundle"
sudo cp -R "$REPO/metal/out/SapphireMetal.bundle" "$MNT/System/Library/Extensions/SapphireMetal.bundle"
sudo chown -R 0:0 "$MNT/System/Library/Extensions/SapphireMetal.bundle"
sudo chmod 755 "$MNT/System/Library/Extensions/SapphireMetal.bundle" "$MNT/System/Library/Extensions/SapphireMetal.bundle/SapphireMetal"
sudo chmod 644 "$MNT/System/Library/Extensions/SapphireMetal.bundle/Info.plist"

echo "=== 3. RedwoodAudio.driver ==="
sudo mkdir -p "$MNT/System/Library/Audio/Plug-Ins/HAL.apple"
for d in "$MNT/System/Library/Audio/Plug-Ins/HAL/"*.driver; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" = "RedwoodAudio.driver" ] && continue
    sudo mv "$d" "$MNT/System/Library/Audio/Plug-Ins/HAL.apple/"
done
sudo rm -rf "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver"
sudo cp -R "$REPO/userland/obj/RedwoodAudio.driver" "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver"
sudo chown -R 0:0 "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver"
sudo chmod 755 "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver" "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/RedwoodAudio"
sudo chmod 644 "$MNT/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/Info.plist"
if [ -d "$MNT/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin" ]; then
    sudo mkdir -p "$MNT/Library/Audio/Plug-Ins/HAL"
    sudo mv "$MNT/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin" "$MNT/Library/Audio/Plug-Ins/HAL/"
fi

echo "=== 4. Procursus + Sileo + ElleKit + OpenSSH ==="
sudo rm -rf "$MNT/private/var/jb"
sudo cp -a "$JB_ROOT" "$MNT/private/var/jb"
for d in var/mobile var/mobile/Library var/mobile/Library/Caches var/mobile/Library/Preferences var/mobile/Documents \
    var/lib/apt/sileolists var/lib/apt/sileolists/partial var/log; do
    sudo mkdir -p "$MNT/private/var/jb/$d"
done
sudo chown -R 501:501 "$MNT/private/var/jb/var/mobile"
sudo chown 501:501 "$MNT/private/var/jb/var/lib/apt/sileolists" "$MNT/private/var/jb/var/lib/apt/sileolists/partial"

for app in "$MNT"/private/var/jb/Applications/*.app; do
    [ -d "$app" ] || continue
    n=$(basename "$app")
    sudo rm -rf "$MNT/Applications/$n"
    (cd "$(dirname "$app")" && sudo tar -cf - "$n") | (cd "$MNT/Applications" && sudo tar -xpf - --same-owner)
done

sudo mkdir -p "$MNT/bin"
for c in chmod cp mkdir mv rm; do
    [ -e "$MNT/bin/$c" ] && [ ! -L "$MNT/bin/$c" ] && continue
    sudo rm -f "$MNT/bin/$c"
    sudo cp -p "$MNT/private/var/jb/usr/bin/$c" "$MNT/bin/$c"
done
[ -L "$MNT/bin/sh" ] || [ -e "$MNT/bin/sh" ] || sudo ln -s /var/jb/bin/sh "$MNT/bin/sh"
[ -L "$MNT/bin/bash" ] || [ -e "$MNT/bin/bash" ] || sudo ln -s /var/jb/bin/bash "$MNT/bin/bash"

sudo cp "$REPO/userland/obj/qmitool" "$REPO/userland/obj/pdpnet" "$REPO/userland/obj/ctdial" "$MNT/private/var/jb/usr/bin/"
sudo chown 0:0 "$MNT/private/var/jb/usr/bin/"{qmitool,pdpnet,ctdial}
sudo chmod 755 "$MNT/private/var/jb/usr/bin/"{qmitool,pdpnet,ctdial}

CFG="$MNT/private/var/jb/etc/ssh/sshd_config"
if [ -f "$CFG" ]; then
    sudo sed -i 's/^UsePAM yes/UsePAM no/' "$CFG"
    sudo bash -c "printf '\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n' >> '$CFG'"
    for t in rsa ecdsa ed25519; do
        [ -f "$MNT/private/var/jb/etc/ssh/ssh_host_${t}_key" ] || \
            sudo ssh-keygen -q -t $t -N "" -C "" -f "$MNT/private/var/jb/etc/ssh/ssh_host_${t}_key"
    done
fi
sudo install -d -m 700 -o 0 -g 0 "$MNT/private/var/root/.ssh"
sudo install -m 600 -o 0 -g 0 "$HOME/.ssh/sapphire_phone.pub" "$MNT/private/var/root/.ssh/authorized_keys"

echo "=== 4b. Fix /etc/passwd and /etc/master.passwd for root user ==="
# Ensure /etc/passwd exists with root and mobile users
sudo bash -c "cat > '$MNT/etc/passwd' <<'EOF'
root:*:0:0:System Administrator:/var/root:/bin/sh
mobile:*:501:501:Mobile User:/var/mobile:/bin/sh
daemon:*:1:1:System Services:/var/root:/usr/bin/false
nobody:*:99:99:Unprivileged User:/var/empty:/usr/bin/false
_wifi:*:74:74:Wi-Fi:/var/empty:/usr/bin/false
_mdnsresponder:*:65:65:mDNSResponder:/var/empty:/usr/bin/false
_sshd:*:75:75:sshd Privilege separation:/var/empty:/usr/bin/false
EOF"

# master.passwd (used by pwd_mkdb on iOS)
sudo bash -c "cat > '$MNT/etc/master.passwd' <<'EOF'
root:*:0:0:System Administrator:/var/root:/bin/sh
mobile:*:501:501:Mobile User:/var/mobile:/bin/sh
daemon:*:1:1:System Services:/var/root:/usr/bin/false
nobody:*:99:99:Unprivileged User:/var/empty:/usr/bin/false
_wifi:*:74:74:Wi-Fi:/var/empty:/usr/bin/false
_mdnsresponder:*:65:65:mDNSResponder:/var/empty:/usr/bin/false
_sshd:*:75:75:sshd Privilege separation:/var/empty:/usr/bin/false
EOF"
sudo chown 0:0 "$MNT/etc/passwd" "$MNT/etc/master.passwd"
sudo chmod 644 "$MNT/etc/passwd" "$MNT/etc/master.passwd"

# Fix sshd_config: ensure PermitRootLogin yes and proper settings
CFG="$MNT/private/var/jb/etc/ssh/sshd_config"
if [ -f "$CFG" ]; then
    sudo sed -i 's/^UsePAM yes/UsePAM no/' "$CFG"
    sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$CFG"
    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$CFG"
    # Add if missing
    if ! grep -q '^PermitRootLogin' "$CFG"; then
        sudo bash -c "echo 'PermitRootLogin yes' >> '$CFG'"
    fi
    if ! grep -q '^PasswordAuthentication' "$CFG"; then
        sudo bash -c "echo 'PasswordAuthentication no' >> '$CFG'"
    fi
    if ! grep -q '^PubkeyAuthentication' "$CFG"; then
        sudo bash -c "echo 'PubkeyAuthentication yes' >> '$CFG'"
    fi
    # Ensure KbdInteractiveAuthentication no
    sudo sed -i 's/^#KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$CFG"
    sudo sed -i 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$CFG"
fi

echo "=== 5. Update launchd.plist ==="
LP="$MNT/System/Library/xpc/launchd.plist"
sudo python3 - "$LP" "$MNT/private/var/jb/Library/LaunchDaemons/com.openssh.sshd.plist" "$REPO/userland/rtcd/com.sapphire.rtcd.plist" <<'PY'
import os, plistlib, sys
lp, ssh_plist, rtcd_plist = sys.argv[1:4]
p = plistlib.load(open(lp, 'rb'))
d = p['LaunchDaemons']
sysd = '/System/Library/LaunchDaemons/'

if os.path.exists(ssh_plist):
    j = plistlib.load(open(ssh_plist, 'rb'))
    j['Sockets'] = {'SSHListener': {'SockServiceName': 'ssh'}}
    j['StandardErrorPath'] = '/var/jb/var/log/sshd-inetd.log'
    d[sysd + 'com.openssh.sshd.plist'] = j

d[sysd + 'com.openssh.sshd2222.plist'] = {
    'Label': 'com.openssh.sshd2222',
    'ProgramArguments': ['/var/jb/usr/sbin/sshd', '-D', '-e', '-p', '2222'],
    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 30, 'UserName': 'root',
    'POSIXSpawnType': 'Interactive',
    'StandardOutPath': '/var/jb/var/log/sshd-2222.log',
    'StandardErrorPath': '/var/jb/var/log/sshd-2222.log',
}

rj = plistlib.load(open(rtcd_plist, 'rb'))
d[sysd + 'com.sapphire.rtcd.plist'] = rj

real = {
    'com.apple.locationd': '/usr/libexec/locationd',
    'com.apple.abm-helper': '/System/Library/PrivateFrameworks/ABMHelper.framework/Support/abm-helper',
}
for label, program in real.items():
    key = sysd + label + '.plist'
    if key in d:
        job = d[key]
        args = job.get('ProgramArguments') or [job.get('Program', program)]
        args = [a for a in args if a != '/redwood/bin/bbstart']
        if not args or args[0] != program:
            args = [program] + args[1:]
        job['ProgramArguments'] = ['/redwood/bin/bbstart'] + args
        job.pop('Program', None)

for gone in ('com.apple.bluetoothd', 'com.apple.fairplayd.H2'):
    for k in [k for k, v in d.items() if v.get('Label') == gone]:
        del d[k]

with open(lp + '.new', 'wb') as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_BINARY)
print('launchd.plist updated:', len(d), 'jobs')
PY
sudo chown --reference="$LP" "$LP.new"
sudo chmod --reference="$LP" "$LP.new"
sudo mv "$LP.new" "$LP"

sudo sync
sudo umount "$MNT"
trap - EXIT

echo "=== 6. fsck.hfsplus ==="
sudo fsck.hfsplus -f -y "$IMG" | grep -v 'Illegal name' || true
echo "USERLAND INSTALLED INTO $IMG OK!"
