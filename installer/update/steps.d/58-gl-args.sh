#!/bin/bash
# 58-gl-args.sh: Create /var/tmp/gl.args for eagl.c to read at runtime
# eagl.c ONLY reads boot args from kern.bootargs sysctl AND /var/tmp/gl.args
# It does NOT read /redwood/boot-args.txt directly!

set -e

echo "=== [58] Creating /var/tmp/gl.args for eagl.c ==="

# eagl.c supported flags (from userland/src/eagl.c):
# vblur=0       : disable Gaussian blur entirely (CRITICAL for Adreno 610 Control Center freeze)
# vblur=2       : mask-based blur (lighter, but still runs shader - NOT enough for CC freeze)
# glwait=1      : wait for GPU at frame end (CRITICAL for Adreno 610 GMEM tiling fix)
# glprecision=0 : keep shader precision as-is (allows mediump/FP16, 2x faster on Adreno)
# glalpha=1     : alpha texture expansion (if needed)
# glnoblank     : disable blank texture optimization
# glnolazy      : disable lazy slice summing
# glnoorphan    : disable orphan upload optimization

mkdir -p /private/var/tmp /var/tmp
cat > /var/tmp/gl.args <<'EOF'
vblur=0 glwait=1 glprecision=0
EOF
chmod 644 /var/tmp/gl.args
cp -f /var/tmp/gl.args /private/var/tmp/gl.args 2>/dev/null || true

# Also create in /redwood for persistence reference
mkdir -p /redwood
cat > /redwood/gl.args <<'EOF'
vblur=0 glwait=1 glprecision=0
EOF
chmod 644 /redwood/gl.args

# Ensure the boot.d script runs at every boot
cat > /redwood/boot.d/58-gl-args.sh <<'BOOT_EOF'
#!/bin/bash
# Create /var/tmp/gl.args for eagl.c at every boot
# eagl.c reads this file at library load time (in backboardd, SpringBoard, apps)
# vblur=0 DISABLES Gaussian blur entirely - critical for Adreno 610 Control Center freeze
# glwait=1 ensures glFinish() at frame_end - critical for Adreno 610 GMEM tiling (no black rectangles)
mkdir -p /private/var/tmp /var/tmp
cat > /var/tmp/gl.args <<'EOF2'
vblur=0 glwait=1 glprecision=0
EOF2
chmod 644 /var/tmp/gl.args
cp -f /var/tmp/gl.args /private/var/tmp/gl.args 2>/dev/null || true
BOOT_EOF
chmod 755 /redwood/boot.d/58-gl-args.sh

echo "=== [58] gl.args configured: vblur=0 glwait=1 glprecision=0 ==="
true