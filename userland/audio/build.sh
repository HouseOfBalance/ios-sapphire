#!/bin/bash
# RedwoodAudio.driver (HackiOS's HAL plug-in, from ios-topaz userland/audio, MIT): the output device
# of iOS, writing to /dev/redwood-audio (kernel 0200). Install on the phone as
# /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver/{RedwoodAudio,Info.plist}, then restart mediaserverd.
# Build: ./build.sh [OUTDIR]
#   RedwoodAudio.driver -> /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver

set -e
cd "$(dirname "$0")"
SDK=${SDK:-$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk}
LDID=${LDID:-$HOME/tools-dl/ldid/ldid}
CC="/usr/lib/llvm-18/bin/clang -target arm64-apple-ios15.0 -isysroot $SDK -fuse-ld=lld -O2 -Wall"
out=${1:-../obj}
mkdir -p "$out/RedwoodAudio.driver"
$CC -bundle -framework CoreFoundation -o "$out/RedwoodAudio.driver/RedwoodAudio" audio_plugin.c
"$LDID" -S "$out/RedwoodAudio.driver/RedwoodAudio"
cp audio_plugin.plist "$out/RedwoodAudio.driver/Info.plist"
echo "$out/RedwoodAudio.driver"
