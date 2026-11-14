#!/bin/bash
set -euo pipefail
# Build base ios16-root.img (16 GiB HFS+) from extracted iPhone X 16.7.16 (20H392) IPSW
IPSW="${1:-$HOME/work/iPhoneX_16.7.16_20H392.ipsw}"
WORK_IPSW="${WORK_IPSW:-$HOME/work/ipsw}"
OUT_DIR="${OUT_DIR:-$HOME/work/out}"
REPO="${REPO:-$HOME/ios-sapphire}"
HFS_KO="${HFS_KO:-$HOME/modules/hfsplus.ko}"

mkdir -p "$WORK_IPSW" "$OUT_DIR" "$REPO/research/ipsw-x"
cd "$WORK_IPSW"
unzip -o -q "$IPSW" Firmware/all_flash/DeviceTree.d22ap.im4p.payload 087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg
cp Firmware/all_flash/DeviceTree.d22ap.im4p.payload "$REPO/research/ipsw-x/d22ap.adt"

rm -f "$OUT_DIR/ios16-root.img" "$OUT_DIR/ios16-root.simg"
sudo "$REPO/tools/sapphire-root.sh" \
    "$WORK_IPSW/087-86698-044.dmg" \
    "$WORK_IPSW/087-86593-047.dmg" \
    "$WORK_IPSW/087-86715-047.dmg" \
    "$OUT_DIR" \
    "$HFS_KO"

ls -lh "$OUT_DIR/ios16-root.img"
