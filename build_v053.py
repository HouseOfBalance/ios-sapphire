import os
import shutil
import tarfile
import zipfile
import subprocess
import glob

REPO = r"C:\Users\TRAN VAN HUNG\Downloads\ios-sapphire"
BUILD = os.path.join(REPO, "build_tmp")
os.makedirs(BUILD, exist_ok=True)
T = os.path.join(BUILD, "staging_053")
if os.path.exists(T):
    shutil.rmtree(T)
os.makedirs(T, exist_ok=True)

root_dir = os.path.join(T, "root")
steps_dir = os.path.join(T, "steps")
os.makedirs(root_dir, exist_ok=True)
os.makedirs(steps_dir, exist_ok=True)

# 1. Unpack recovery zip
rec_zip = os.path.join(REPO, "sapphire-recovery.zip")
print(f"Extracting base binaries from {rec_zip}...")
with zipfile.ZipFile(rec_zip, 'r') as zf:
    for f in zf.namelist():
        if f.startswith("sapphire/ios/files/"):
            rel = os.path.relpath(f, "sapphire/ios/files")
            target = os.path.join(root_dir, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as out:
                out.write(zf.read(f))
        elif f.startswith("sapphire/ios/Android.app/"):
            rel = os.path.relpath(f, "sapphire/ios")
            target = os.path.join(root_dir, "Applications", rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as out:
                out.write(zf.read(f))
        elif f.startswith("sapphire/ios/tweaks/"):
            rel_name = os.path.basename(f)
            if rel_name:
                tweak_dir = os.path.join(root_dir, "private", "var", "jb", "usr", "lib", "TweakInject")
                os.makedirs(tweak_dir, exist_ok=True)
                with open(os.path.join(tweak_dir, rel_name), "wb") as out:
                    out.write(zf.read(f))
        elif f == "sapphire/firstboot.sh":
            fb_target = os.path.join(root_dir, "redwood", "bin", "sapphire-firstboot.sh.in")
            os.makedirs(os.path.dirname(fb_target), exist_ok=True)
            with open(fb_target, "wb") as out:
                out.write(zf.read(f))

# Re-sign Android.app with full entitlements using WSL ldid
android_bin = os.path.join(root_dir, "Applications", "Android.app", "Android")
ent_path = os.path.join(REPO, "userland", "dualboot", "ios-app", "AndroidBoot.entitlements")
if os.path.exists(android_bin) and os.path.exists(ent_path):
    print("Signing Android.app with AndroidBoot.entitlements via WSL ldid...")
    wsl_bin = "/mnt/c/" + android_bin[3:].replace("\\", "/")
    wsl_ent = "/mnt/c/" + ent_path[3:].replace("\\", "/")
    cmd = ["wsl", "/home/khanh/tools-dl/ldid/ldid", f"-S{wsl_ent}", wsl_bin]
    res = subprocess.run(cmd, capture_output=True, text=True)
    print(f"  ldid result: code={res.returncode}")

# 2. Copy files from installer/update/files
up_files = os.path.join(REPO, "installer", "update", "files")
if os.path.exists(up_files):
    print("Copying installer/update/files...")
    for item in os.listdir(up_files):
        s = os.path.join(up_files, item)
        d = os.path.join(root_dir, item)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)

# 3. Copy userland binaries from userland/obj/
obj_dir = os.path.join(REPO, "userland", "obj")
bin_dir = os.path.join(root_dir, "redwood", "bin")
lib_dir = os.path.join(root_dir, "redwood", "lib")
tweak_dir = os.path.join(root_dir, "private", "var", "jb", "usr", "lib", "TweakInject")
tweaks_redwood = os.path.join(root_dir, "redwood", "tweaks")
inbox_dir = os.path.join(root_dir, "redwood", "inbox")

os.makedirs(bin_dir, exist_ok=True)
os.makedirs(lib_dir, exist_ok=True)
os.makedirs(tweak_dir, exist_ok=True)
os.makedirs(tweaks_redwood, exist_ok=True)
os.makedirs(inbox_dir, exist_ok=True)

# Binaries -> /redwood/bin
bins = ["sensord", "vibd", "thermald", "btmonitor", "ccstart", "bbstart", "pdpnet", "qmitool", "ctdial", "fpd", "fpload", "fpsave", "fpctl"]
for b in bins:
    src = os.path.join(obj_dir, b)
    if os.path.exists(src):
        dst = os.path.join(bin_dir, b)
        shutil.copy2(src, dst)
        print(f"  ✓ Copied binary {b} to redwood/bin")

# Libraries -> /redwood/lib
libs = ["ccbridge.dylib", "libsapphire-fakebb.dylib", "eagl.dylib", "libredwood-gl.dylib", "libredwood-glload.dylib"]
for l in libs:
    src = os.path.join(obj_dir, l)
    if os.path.exists(src):
        dst = os.path.join(lib_dir, l)
        shutil.copy2(src, dst)
        print(f"  ✓ Copied library {l} to redwood/lib")

# Tweaks -> TweakInject & /redwood/tweaks
tweaks = [
    "SapphireBTCapability.dylib", "SapphireBTCapability.plist",
    "SapphireFingerprint.dylib", "SapphireFingerprint.plist",
    "SapphireFingerprintSettings.dylib", "SapphireFingerprintSettings.plist"
]
for tw in tweaks:
    src = os.path.join(obj_dir, tw)
    if os.path.exists(src):
        shutil.copy2(src, os.path.join(tweak_dir, tw))
        shutil.copy2(src, os.path.join(tweaks_redwood, tw))
        print(f"  ✓ Copied tweak {tw} to TweakInject & redwood/tweaks")

# Huella.ipa -> /redwood/inbox
huella_ipa = os.path.join(obj_dir, "Huella.ipa")
if os.path.exists(huella_ipa):
    shutil.copy2(huella_ipa, os.path.join(inbox_dir, "Huella.ipa"))
    print("  ✓ Placed Huella.ipa in redwood/inbox for TrollStore")

# Kernel -> /System/Library/Kernels/kernel.development.sweet
kernel_src = os.path.join(REPO, "build_tmp", "xnu_4k_extracted", "kernel.development.sweet")
if os.path.exists(kernel_src):
    k_dst_dir = os.path.join(root_dir, "System", "Library", "Kernels")
    os.makedirs(k_dst_dir, exist_ok=True)
    shutil.copy2(kernel_src, os.path.join(k_dst_dir, "kernel.development.sweet"))
    print("  ✓ Copied kernel.development.sweet (XNU 4K) to System/Library/Kernels")

# 4. Copy steps from installer/update/steps.d
up_steps = os.path.join(REPO, "installer", "update", "steps.d")
print("Copying steps.d scripts...")
for f in sorted(glob.glob(os.path.join(up_steps, "*.sh"))):
    name = os.path.basename(f)
    dest = os.path.join(steps_dir, name)
    with open(f, 'rb') as inf:
        content = inf.read().replace(b'\r\n', b'\n')
    with open(dest, 'wb') as outf:
        outf.write(content)
    print(f"  Added step: {name}")

# 5. Write update.sh
update_sh = """#!/var/jb/bin/bash
# update.sh DIR: run by sapphire-update.sh as root, at boot. DIR/root's files go to /.
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
D=$1
V=$(cat $D/VERSION)
echo "Sapphire update $V"
old=/redwood/bin/sapphire-firstboot.sh
ver=$(sed -n 's/^VERSION=\\([^ ]*\\).*/\\1/p' $old 2>/dev/null | head -1)
bld=$(sed -n 's/^BUILD=\\([^ ]*\\).*/\\1/p' $old 2>/dev/null | head -1)
sed "s/@VERSION@/${ver:-16.7.16}/; s/@BUILD@/${bld:-20H392}/" $D/root/redwood/bin/sapphire-firstboot.sh.in > $D/root/redwood/bin/sapphire-firstboot.sh
rm -f $D/root/redwood/bin/sapphire-firstboot.sh.in
chmod 755 $D/root/redwood/bin/* 2>/dev/null || true
chown -R 0:0 $D/root
for a in $D/root/Applications/*.app; do
    [ -d "$a" ] && rm -rf "/Applications/${a##*/}"
done
tar -C $D/root -cf - . | tar -C / -xpf - --no-overwrite-dir
echo "$V" > /redwood/version
SAPPHIRE_UPDATING=1 bash /redwood/bin/sapphire-firstboot.sh || true
for s in $D/steps/*.sh; do
    [ -f "$s" ] && { echo "step ${s##*/}"; bash "$s" || echo "step ${s##*/} failed"; }
done
for j in /redwood/launchd/*.plist; do
    [ -f "$j" ] && { launchctl unload "$j" 2>/dev/null; launchctl load "$j" || true; }
done
for s in /redwood/boot.d/*.sh; do
    [ -f "$s" ] && bash "$s" || true
done
echo "Sapphire update $V applied"
"""
with open(os.path.join(T, "update.sh"), "wb") as f:
    f.write(update_sh.encode('utf-8'))

# 6. Write VERSION
with open(os.path.join(T, "VERSION"), "wb") as f:
    f.write(b"0.5.3\n")

# 7. Build the tar.gz
out_tar = os.path.join(BUILD, "sapphire-update-0.5.3.supdate")
print(f"Creating archive {out_tar}...")
with tarfile.open(out_tar, "w:gz") as tar:
    for item in ["update.sh", "VERSION", "root", "steps"]:
        p = os.path.join(T, item)
        tar.add(p, arcname=item)

print(f"Update package v0.5.3 built successfully! Size: {os.path.getsize(out_tar)} bytes")
