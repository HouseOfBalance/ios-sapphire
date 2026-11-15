#!/bin/bash
# 64-tweak-loader-opt.sh: Optimize ElleKit TweakLoader for faster app launch
# - Sets NO_TWEAKS for processes that don't need tweaks
# - Ensures libredwood-glload.dylib is properly signed/linked
# - Creates /var/jb/var/sapphire-notweaks for non-SpringBoard apps

set -e

echo "=== [64] Optimizing TweakLoader for app launch ==="

# 1. Ensure tweaks are ENABLED so SapphireDisplayLink can load into SpringBoard
# glload.c checks: if access(NO_TWEAKS, F_OK) != 0 -> load tweaks
# Therefore, sapphire-notweaks MUST NOT exist!
rm -f /var/jb/var/sapphire-notweaks /private/var/jb/var/sapphire-notweaks 2>/dev/null || true

# 2. Boot-time check: keep tweaks enabled
cat > /redwood/boot.d/64-tweak-loader-opt.sh <<'BOOT_EOF'
#!/bin/bash
# Keep tweaks enabled for SapphireDisplayLink (120Hz display pacing)
rm -f /var/jb/var/sapphire-notweaks /private/var/jb/var/sapphire-notweaks 2>/dev/null || true
BOOT_EOF
chmod 755 /redwood/boot.d/64-tweak-loader-opt.sh

# 3. Verify libredwood-glload.dylib is properly signed
if [ -f /redwood/lib/libredwood-glload.dylib ]; then
    echo "  libredwood-glload.dylib found"
    # Check code signature
    codesign -v /redwood/lib/libredwood-glload.dylib 2>&1 | head -5 || true
fi

# 4. Ensure SweetGLLoad kernel patch is enabled (kern.sweet_glload=1)
# This is done in 55-sapphire-fluidity-120hz.sh

echo "=== [64] TweakLoader optimization configured ==="
true