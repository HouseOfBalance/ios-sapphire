#!/bin/bash
set -euo pipefail
export LLVM="${LLVM:-/usr/lib/llvm-18/bin}"
export PATH="$LLVM:$PATH"
export SDK="${SDK:-$HOME/work/sdks/theos-sdks/iPhoneOS16.5.sdk}"
export B="${B:-$HOME/work/mesa-ios}"
export M="${M:-$B/out}"
export JB_OUT="${JB_OUT:-$HOME/work/jb-build}"
REPO="${REPO:-$HOME/ios-sapphire}"

cd "$REPO"

echo "=== 1. SapphireMetal.bundle ==="
LD64="$LLVM/ld64.lld" ./metal/build.sh

echo "=== 2. RedwoodAudio.driver ==="
./userland/audio/build.sh

echo "=== 3. Telephony ==="
./userland/telephony/build.sh

echo "=== 4. Mesa 25.0.7 ==="
./userland/mk-mesa.sh

echo "=== 5. EAGL bridge ==="
./userland/build-gl.sh

echo "=== 6. Procursus + Sileo + ElleKit ==="
./userland/jb/mk-jb.sh

echo "=== ALL USERLAND BUILT OK ==="
ls -lh userland/obj/ "$M/libOSMesa.8.dylib" "$JB_OUT/"
