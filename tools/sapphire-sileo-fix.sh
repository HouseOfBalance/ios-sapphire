#!/bin/bash
# Sileo's settings and apt's, in the iOS root image, as root in WSL (after mA.sh, before mC.sh):
#   - ShowProvisional (Canister search) off: its servers cannot be reached, the asking never stops and
#     the package downloads never get their turn (HackiOS's finding; their inject_app.c sets it at start).
#     Written in the global preferences and in Sileo's data container, owned by mobile.
#   - apt stays root (APT::Sandbox::User): the prefix has no pwd.db, so "_apt" cannot be looked up.
#   - Sileo's dead downloads (0-byte CFNetworkDownload_*.tmp) removed.
# OUTDIR/files.runs: the blocks of the files written.
#   sapphire-sileo-fix.sh IMG OUTDIR
set -euo pipefail
img=$1 out=$2
mnt=/mnt/ios
mkdir -p "$out" "$mnt"
grep -qw hfsplus /proc/filesystems || insmod /home/angel/ios-build/hfsplus.ko
trap 'mountpoint -q "$mnt" && umount "$mnt"' EXIT
mount -t hfsplus -o loop,force "$img" "$mnt"
files=""
write_prefs() {
	python3 -I -c 'import plistlib, sys; p = sys.argv[1]
d = {}
try:
    d = plistlib.load(open(p, "rb"))
except Exception:
    pass
d["ShowProvisional"] = False
plistlib.dump(d, open(p, "wb"), fmt=plistlib.FMT_BINARY)' "$1"
	chown 501:501 "$1"
	chmod 600 "$1"
	files="$files $1"
}
write_prefs "$mnt/private/var/mobile/Library/Preferences/org.coolstar.SileoStore.plist"
for c in "$mnt"/private/var/mobile/Containers/Data/Application/*/; do
	if [ -d "$c/Library/Caches/org.coolstar.SileoStore" ]; then
		mkdir -p "$c/Library/Preferences"
		write_prefs "$c/Library/Preferences/org.coolstar.SileoStore.plist"
		find "$c/tmp" -maxdepth 1 -name 'CFNetworkDownload_*.tmp' -size 0 -delete
		echo "Sileo's container: ${c#$mnt}"
	fi
done
conf="$mnt/private/var/jb/etc/apt/apt.conf.d/20sapphire-sandbox.conf"
cat > "$conf" <<'APTEOF'
APT::Sandbox::User "root";
Dir::Bin::methods "/var/jb/usr/lib/apt/methods";
Dir::Bin::solvers "/var/jb/usr/lib/apt/solvers";
APT::Sandbox::Seccomp "false";
DPkg::Pre-Install-Pkgs {"/var/jb/usr/libexec/dpkg-pre-install";};
APTEOF
chmod 644 "$conf"
files="$files $conf"

# Ensure CaInfo is set for HTTPS (libgnutls needs this)
ca_conf="$mnt/private/var/jb/etc/apt/apt.conf.d/10sapphire.conf"
if [ ! -f "$ca_conf" ]; then
    echo 'Acquire::https::CaInfo "/var/jb/etc/ssl/certs/cacert.pem";' > "$ca_conf"
    chmod 644 "$ca_conf"
    files="$files $ca_conf"
fi

# Fix apt-get wrapper if it exists (redirect log to /tmp)
apt_get_wrapper="$mnt/private/var/jb/usr/bin/apt-get"
if [ -f "$apt_get_wrapper" ]; then
    sed -i 's|/var/jb/var/log/aptwrap.log|/tmp/aptwrap.log|g' "$apt_get_wrapper" 2>/dev/null || true
fi

# Ensure https method symlink exists
methods_dir="$mnt/private/var/jb/usr/lib/apt/methods"
if [ -f "$methods_dir/http" ] && [ ! -L "$methods_dir/https" ]; then
    ln -sf http "$methods_dir/https"
    chmod 755 "$methods_dir/https"
fi

# Fix log permissions
log_dir="$mnt/private/var/jb/var/log"
mkdir -p "$log_dir"
chmod 777 "$log_dir"
touch "$log_dir/aptwrap.log"
chmod 666 "$log_dir/aptwrap.log"
chown 501:501 "$log_dir/aptwrap.log"
sync
python3 -I - $files > "$out/files.runs" <<'PY'
import fcntl, os, struct, sys
runs = []
for p in sys.argv[1:]:
    n = (os.path.getsize(p) + 4095) // 4096
    fd = os.open(p, os.O_RDONLY)
    for i in range(n):
        b = struct.unpack('I', fcntl.ioctl(fd, 1, struct.pack('I', i)))[0]
        if b:
            runs.append((b, 1))
    os.close(fd)
for s, c in runs:
    print(s, c)
PY
echo "written:$files"
