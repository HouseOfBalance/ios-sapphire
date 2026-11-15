#!/bin/bash
set -e
insmod /home/khanh/modules/hfsplus.ko 2>/dev/null || true
nbd-client -d /dev/nbd0 2>/dev/null || true
HOST_IP=$(ip route | grep default | awk '{print $3}')
[ -z "$HOST_IP" ] && HOST_IP="172.20.160.1"
nbd-client "$HOST_IP" 10810 /dev/nbd0 -b 4096
mkdir -p /mnt/iosroot
fsck.hfsplus -y /dev/nbd0 || true
mount -t hfsplus -o force,rw /dev/nbd0 /mnt/iosroot

LDID="/home/khanh/tools-dl/ldid/ldid"

echo "=== 1. Sign all unsigned binaries in /redwood/bin ==="
for b in btmonitor fpctl fpd fpload fpsave sensord thermald vibd; do
    if [ -f "/mnt/iosroot/redwood/bin/$b" ]; then
        "$LDID" -S "/mnt/iosroot/redwood/bin/$b" || true
        chmod 755 "/mnt/iosroot/redwood/bin/$b"
        chown 0:0 "/mnt/iosroot/redwood/bin/$b"
        echo "  ✓ Signed $b with ldid"
    fi
done

echo "=== 2. Remove com.sapphire.vibd from launchd cache ==="
python3 - << 'PYEOF'
import plistlib, sys

KEY = '/System/Library/LaunchDaemons/com.sapphire.vibd.plist'
P = '/mnt/iosroot/System/Library/xpc/launchd.plist'
raw = open(P, 'rb').read()
fmt = plistlib.FMT_BINARY if raw[:8] == b'bplist00' else plistlib.FMT_XML
p = plistlib.loads(raw)
d = p['LaunchDaemons']
before = len(d)
if KEY in d:
    del d[KEY]
    with open(P, 'wb') as f:
        plistlib.dump(p, f, fmt=fmt)
    print(f"Removed {KEY}: jobs {before} -> {len(d)}")
else:
    print(f"{KEY} not in cache")
PYEOF

chown 0:0 /mnt/iosroot/System/Library/xpc/launchd.plist
chmod 644 /mnt/iosroot/System/Library/xpc/launchd.plist

echo "=== 3. Deploy 96-vibd.sh to /redwood/boot.d ==="
cat > /mnt/iosroot/redwood/boot.d/96-vibd.sh << 'EOF'
#!/bin/bash
# 96-vibd.sh: Start haptic vibration daemon (vibd) at boot
# Avoids system launchd cache platform binary panic
if [ -x /redwood/bin/vibd ]; then
    echo "[96-vibd] Starting haptic daemon..."
    nohup /redwood/bin/vibd > /var/tmp/vibd.out 2>&1 &
fi
exit 0
EOF
chmod 755 /mnt/iosroot/redwood/boot.d/96-vibd.sh
chown 0:0 /mnt/iosroot/redwood/boot.d/96-vibd.sh

echo "=== 4. Verify signatures of all binaries in /redwood/bin ==="
python3 - << 'PYEOF'
import os, struct, glob

for f in sorted(glob.glob('/mnt/iosroot/redwood/bin/*')):
    if not os.path.isfile(f) or f.endswith('.sh') or f.endswith('.in'):
        continue
    data = open(f, 'rb').read()
    if len(data) < 32: continue
    magic = struct.unpack('<I', data[:4])[0]
    if magic != 0xfeedfacf and magic != 0xfeedface: continue
    ncmds = struct.unpack('<I', data[16:20])[0]
    offset = 32
    has_sig = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[offset:offset+8])
        if cmd == 0x1d:
            has_sig = True
            break
        offset += cmdsize
    if not has_sig:
        print(f"  WARNING: {os.path.basename(f)} STILL HAS NO SIGNATURE!")
    else:
        print(f"  ✓ {os.path.basename(f)} signed")

PYEOF

sync
umount /mnt/iosroot
nbd-client -d /dev/nbd0
echo "=== DONE CLEANLY ==="
