#!/bin/bash
# make-update.sh VERSION [OUT_DIR]: a Sapphire update (sapphire-update-VERSION.supdate, a .tar.gz)
# for the installer's update mode. The phone keeps everything (iOS, apps, data); the update brings
# files and an update.sh that iOS runs as root at its next boot (userland/update/sapphire-update.sh), once.
#
# What goes in:
# - Everything under files/ (paths as on the phone: files/redwood/bin/x -> /redwood/bin/x)
# - Current builds of per-boot scripts, the updater, and launchd jobs
# - steps.d/NN-*.sh (idempotent, in name order), run by update.sh as root after the files
# - GL libraries (libredwood-glload.dylib, libredwood-gl.dylib)
# - Tweaks (ElleKit based)
# - Dual-boot Android app
#
# Usage: ./make-update.sh [VERSION] [OUT_DIR]
# Example: ./make-update.sh 0.4.7 out/

set -e

H=$(cd "$(dirname "$0")" && pwd)
I=$(cd "$H/.." && pwd)
V=${1:-$(cat "$I/VERSION" 2>/dev/null || echo "0.4.7")}
OUT=${2:-"$I/out"}
T=$(mktemp -d)
R=$T/root
mkdir -p "$R/redwood/bin" "$R/redwood/boot.d" "$R/redwood/launchd" "$R/redwood/lib" "$R/redwood/patches" "$OUT"

echo "=== Building Sapphire update v$V ==="

# 1. Copy recovery firstboot script (template)
cp "$I/recovery/firstboot.sh" "$R/redwood/bin/sapphire-firstboot.sh.in"

# 2. Build userland binaries
echo "Building userland binaries..."
bash "$I/../userland/update/build.sh" "$R/redwood/bin" >/dev/null

# 3. Copy files/ tree (persistent files that go to / on device)
if [ -d "$H/files" ]; then
    echo "Copying files/ tree..."
    cp -a "$H/files/." "$R/"
fi

# 3b. Build fingerprint components (fpd, Huella app, tweaks) - AFTER files/ tree so our fresh build wins
echo "Building fingerprint components..."
FINGERPRINT_OUT=$(mktemp -d)
bash "$I/../userland/fingerprint/build.sh" "$FINGERPRINT_OUT" >/dev/null

# Copy fingerprint binaries to redwood/bin
cp "$FINGERPRINT_OUT/fpd" "$FINGERPRINT_OUT/fpload" "$FINGERPRINT_OUT/fpsave" "$FINGERPRINT_OUT/fpctl" "$R/redwood/bin/"
cp "$FINGERPRINT_OUT/com.sapphire.fpd.plist" "$R/redwood/share/fpd/" 2>/dev/null || mkdir -p "$R/redwood/share/fpd" && cp "$FINGERPRINT_OUT/com.sapphire.fpd.plist" "$R/redwood/share/fpd/"

# Copy 95-fpd.sh to redwood/boot.d/ (starts fpd via boot.d without launchd cache panic)
mkdir -p "$R/redwood/boot.d"
if [ -f "$I/../userland/fingerprint/95-fpd.sh" ]; then
    cp "$I/../userland/fingerprint/95-fpd.sh" "$R/redwood/boot.d/95-fpd.sh"
    chmod 755 "$R/redwood/boot.d/95-fpd.sh"
    echo "  ✓ 95-fpd.sh copied to redwood/boot.d"
fi

# Copy tweaks to TweakInject
mkdir -p "$R/private/var/jb/usr/lib/TweakInject"
cp "$FINGERPRINT_OUT/SapphireFingerprint.dylib" "$FINGERPRINT_OUT/SapphireFingerprint.plist" "$FINGERPRINT_OUT/SapphireFingerprintSettings.dylib" "$FINGERPRINT_OUT/SapphireFingerprintSettings.plist" "$R/private/var/jb/usr/lib/TweakInject/"

# Huella.app has platform-application + no-sandbox entitlements.
# On iOS 16, AMFI will SIGKILL it if copied directly to /Applications.
# Instead, place Huella.ipa in the Sapphire inbox so sapphire-ipa-install.sh
# installs it via TrollStore (which handles the fake-signing correctly).
mkdir -p "$R/redwood/inbox"
cp "$FINGERPRINT_OUT/Huella.ipa" "$R/redwood/inbox/Huella.ipa"
echo "  ✓ Huella.ipa placed in inbox for TrollStore installation"

rm -rf "$FINGERPRINT_OUT"

# 4. Copy steps.d scripts (run by update.sh at boot)
echo "Copying steps.d scripts..."
mkdir -p "$T/steps"
if [ -d "$H/steps.d" ]; then
    cp "$H/steps.d"/*.sh "$T/steps/" 2>/dev/null
fi

# 5. Build GL loader bridge (libredwood-glload.dylib)
echo "Building libredwood-glload.dylib..."
mkdir -p "$R/redwood/lib"
SDK="$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk"
/usr/lib/llvm-18/bin/clang -target arm64-apple-ios16.0 -isysroot "$SDK" -fuse-ld=lld -O2 -Wall -dynamiclib \
    -install_name /redwood/lib/libredwood-glload.dylib -framework CoreFoundation \
    -o "$R/redwood/lib/libredwood-glload.dylib" \
    "$I/../userland/src/glload.c"
LDID=$(find ~/tools-dl/ldid -type f -name ldid | head -1)
$LDID -S "$R/redwood/lib/libredwood-glload.dylib"

# 6. Build GL bridge (libredwood-gl.dylib) - loaded by backboardd/apps
echo "Building libredwood-gl.dylib..."
M="$HOME/mesa-ios/out" SDK="$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk" bash "$I/../userland/build-gl.sh" >/dev/null
cp "$I/../userland/obj/libredwood-gl.dylib" "$R/redwood/lib/"
$LDID -S "$R/redwood/lib/libredwood-gl.dylib"

# 6b. Copy userland binaries from build output (built by build_all.sh)
echo "Copying userland binaries from build output..."
for bin in sensord vibd thermald btmonitor ccstart bbstart pdpnet qmitool ctdial; do
    if [ -f "$I/../userland/obj/$bin" ]; then
        cp "$I/../userland/obj/$bin" "$R/redwood/bin/"
        $LDID -S "$R/redwood/bin/$bin" 2>/dev/null || true
        echo "  ✓ $bin copied to redwood/bin"
    else
        echo "  ⚠ $bin not found in build output (run build_all.sh first)"
    fi
done
# Copy RedwoodAudio.driver
if [ -d "$I/../userland/obj/RedwoodAudio.driver" ]; then
    cp -a "$I/../userland/obj/RedwoodAudio.driver" "$R/System/Library/Audio/Plug-Ins/HAL/"
    echo "  ✓ RedwoodAudio.driver copied"
fi
# Copy SapphireHaptics.dylib
if [ -f "$I/../userland/obj/SapphireHaptics.dylib" ]; then
    cp "$I/../userland/obj/SapphireHaptics.dylib" "$R/redwood/tweaks/"
    $LDID -S "$R/redwood/tweaks/SapphireHaptics.dylib" 2>/dev/null || true
    echo "  ✓ SapphireHaptics.dylib copied"
fi
# Copy eagl.dylib
if [ -f "$I/../userland/obj/eagl.dylib" ]; then
    cp "$I/../userland/obj/eagl.dylib" "$R/redwood/lib/"
    $LDID -S "$R/redwood/lib/eagl.dylib" 2>/dev/null || true
    echo "  ✓ eagl.dylib copied"
fi
# Copy telephony libraries
for lib in ccbridge.dylib libsapphire-fakebb.dylib bdsandbox.dylib libredwood-gl.dylib libredwood-glload.dylib; do
    if [ -f "$I/../userland/obj/$lib" ]; then
        cp "$I/../userland/obj/$lib" "$R/redwood/lib/"
        $LDID -S "$R/redwood/lib/$lib" 2>/dev/null || true
        echo "  ✓ $lib copied to redwood/lib"
    else
        echo "  ⚠ $lib not found in build output"
    fi
done

# 7. Build tweaks (ElleKit)
echo "Building tweaks..."
mkdir -p "$R/private/var/jb/usr/lib/TweakInject"
mkdir -p "$R/redwood/tweaks"  # For on-device tweak deployment (e.g., SapphireBTCapability)
bash "$I/../userland/tweaks/safari/build.sh" "$R/private/var/jb/usr/lib/TweakInject" >/dev/null
LDID=$(find ~/tools-dl/ldid -type f -name ldid | head -1) SDK="$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk" \
    bash "$I/../userland/tweaks/displaylink/build.sh" "$R/private/var/jb/usr/lib/TweakInject" >/dev/null
LDID=$(find ~/tools-dl/ldid -type f -name ldid | head -1) SDK="$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk" \
    bash "$I/../userland/tweaks/heif/build.sh" "$R/private/var/jb/usr/lib/TweakInject" >/dev/null
LDID=$(find ~/tools-dl/ldid -type f -name ldid | head -1) SDK="$HOME/sdks/theos-sdks/iPhoneOS16.5.sdk" \
    bash "$I/../userland/tweaks/btcapability/build.sh" "$R/redwood/tweaks" >/dev/null
# Also copy btcapability to device TweakInject
if [ -f "$R/redwood/tweaks/SapphireBTCapability.dylib" ]; then
    cp "$R/redwood/tweaks/SapphireBTCapability.dylib" "$R/private/var/jb/usr/lib/TweakInject/"
    cp "$R/redwood/tweaks/SapphireBTCapability.plist" "$R/private/var/jb/usr/lib/TweakInject/"
    echo "  ✓ SapphireBTCapability copied to device TweakInject"
fi

# 8. Build dual-boot Android app (replaces /Applications/Android.app)
echo "Building dual-boot Android app..."
LDID=$(find ~/tools-dl/ldid -type f -name ldid | head -1) bash "$I/../userland/dualboot/build-ios-app.sh" >/dev/null
mkdir -p "$R/Applications"
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$I/../userland/dualboot/out/Android.ipa" "$T/ipa"
mv "$T/ipa/Payload/Android.app" "$R/Applications/"
chmod 755 "$R/Applications/Android.app/Android"
rm -rf "$T/ipa"

# 9. Generate launchd plists from recipes
echo "Generating launchd plists..."
for j in com.sapphire.appwatch com.sapphire.ipa-install com.sapphire.sign-binaries com.sapphire.btaudio; do
    if [ -f "$I/recipes/launchd/$j.plist" ]; then
        python3 - "$I/recipes/launchd/$j.plist" "$R/redwood/launchd/$j.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
plistlib.dump(d["Job"], open(sys.argv[2], "wb"), fmt=plistlib.FMT_XML)
PY
        cat > "$R/redwood/boot.d/50-$j.sh" <<EOF
# $j: a launchd job outside launchd's cache, loaded at every boot (make-update.sh)
launchctl list $j >/dev/null 2>&1 || launchctl load /redwood/launchd/$j.plist
EOF
    fi
done

# Copy btmonitor plist from userland (built by btmonitor Makefile)
if [ -f "$I/../userland/bluetooth/com.sapphire.btmonitor.plist" ]; then
    cp "$I/../userland/bluetooth/com.sapphire.btmonitor.plist" "$R/redwood/launchd/"
    cat > "$R/redwood/boot.d/50-com.sapphire.btmonitor.sh" <<'EOF'
# com.sapphire.btmonitor: btmonitor daemon for Bluetooth HCI event monitoring
launchctl list com.sapphire.btmonitor >/dev/null 2>&1 || launchctl load /redwood/launchd/com.sapphire.btmonitor.plist
EOF
fi

# 10. Copy kernel patches to redwood/patches (for reference/update)
echo "Copying kernel patches..."
if [ -d "$I/redwood/patches" ]; then
    cp "$I/redwood/patches"/*.patch "$R/redwood/patches/" 2>/dev/null || true
fi

# 11. Create update.sh (runs on device at boot as root)
cat > "$T/update.sh" <<'EOF'
#!/var/jb/bin/bash
# update.sh DIR: run by sapphire-update.sh as root, at boot. DIR/root's files go to /.
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
D=$1
V=$(cat "$D/VERSION")
echo "Sapphire update $V"

# The per-boot script keeps this phone's iOS version and build (filled in at install)
old=/redwood/bin/sapphire-firstboot.sh
ver=$(sed -n 's/^VERSION=\([^ ]*\).*/\1/p' "$old" 2>/dev/null | head -1)
bld=$(sed -n 's/^BUILD=\([^ ]*\).*/\1/p' "$old" 2>/dev/null | head -1)
sed "s/@VERSION@/${ver:-16.7.16}/; s/@BUILD@/${bld:-20H392}/" "$D/root/redwood/bin/sapphire-firstboot.sh.in" > "$D/root/redwood/bin/sapphire-firstboot.sh"
rm "$D/root/redwood/bin/sapphire-firstboot.sh.in"
chmod 755 "$D/root/redwood/bin"/*

# Ownership for copied files
chown -R 0:0 "$D/root"

# An app replaced as a whole (its old files must not linger)
for a in "$D/root/Applications"/*.app; do
    [ -d "$a" ] && rm -rf "/Applications/${a##*/}"
done

# Into /, leaving metadata of directories that already exist alone (/, /redwood...)
tar -C "$D/root" -cf - . | tar -C / -xpf - --no-overwrite-dir

echo "$V" > /redwood/version

# Run per-boot firstboot steps (exits at once-only part if already done)
SAPPHIRE_UPDATING=1 bash /redwood/bin/sapphire-firstboot.sh || true

# Run steps.d scripts in order
for s in "$D/steps"/*.sh; do
    [ -f "$s" ] && { echo "step ${s##*/}"; bash "$s" || echo "step ${s##*/} failed"; }
done

# Reload launchd jobs outside cache (so changed ones take effect now)
for j in /redwood/launchd/*.plist; do
    [ -f "$j" ] && { launchctl unload "$j" 2>/dev/null; launchctl load "$j" || true; }
done

# Run boot.d scripts
for s in /redwood/boot.d/*.sh; do
    [ -f "$s" ] && bash "$s" || true
done

echo "Sapphire update $V applied"
EOF

echo "$V" > "$T/VERSION"
chmod 755 "$T/update.sh"

# 12. Create final .supdate package
F="$OUT/sapphire-update-$V.supdate"
echo "Creating package: $F"
tar -C "$T" --owner=0 --group=0 -czf "$F" update.sh VERSION root steps
rm -rf "$T"

echo ""
echo "=== Package created successfully ==="
ls -lh "$F"
echo ""
echo "Contents preview:"
tar -tzvf "$F" | head -40
echo ""
echo "To deploy: copy $F to device as .supdate on iosroot partition"
echo "Or use: adb push $F /sdcard/ && adb shell 'cp /sdcard/sapphire-update-$V.supdate /redwood/inbox/'"
echo "Then reboot to iOS - sapphire-update.sh will apply it automatically"

true