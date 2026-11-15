#!/bin/bash
# 87-zero-jank-ultra-fluidity.sh: Phase 4 Zero-Jank 120Hz/60FPS Ultra Fluidity
# Targets: 100% jank-free on Redmi Note 13 4G (SM6225/Adreno 610)
# Addresses 5 root causes: GPU Pipeline Stall, KGSL Governor Latency, Touch IRQ Affinity,
# QuartzCore Blur Stalling, CPU EAS & I/O Throttling

set -e

echo "=== [87] Phase 4 Zero-Jank Ultra Fluidity (v0.5.0) ==="

# ─────────────────────────────────────────────────────────────────
# 1. KGSL GPU FREQUENCY GOVERNOR - ELIMINATE SCALING LATENCY
# ─────────────────────────────────────────────────────────────────
echo "Configuring KGSL GPU Governor for instant frequency response..."

cat > /redwood/boot.d/87-kgsl-gpu-governor.sh <<'KGSL_EOF'
#!/bin/bash
# KGSL GPU Governor tuning for Adreno 610 (Snapdragon 685)
# Eliminates 30-50ms frequency scaling latency causing micro-stutter

# Paths (may vary by kernel version)
KGSL_PATH="/sys/class/kgsl/kgsl-3d0"
DEVFREQ_PATH="/sys/class/devfreq/5000000.gpu"

# 1. Set governor to 'msm-adreno-tz' for proper idle power-gating
if [ -f "$KGSL_PATH/devfreq/governor" ]; then
    echo "msm-adreno-tz" > "$KGSL_PATH/devfreq/governor" 2>/dev/null || true
    echo "  Governor: $(cat $KGSL_PATH/devfreq/governor 2>/dev/null)"
fi

# 2. Set min/max GPU clocks (Adreno 610: 310MHz idle floor - 1114MHz dynamic ceiling)
if [ -f "$KGSL_PATH/devfreq/min_freq" ]; then
    echo "310000000" > "$KGSL_PATH/devfreq/min_freq" 2>/dev/null  # 310 MHz idle floor (cool!)
    echo "  Min freq: $(cat $KGSL_PATH/devfreq/min_freq 2>/dev/null) Hz"
fi
if [ -f "$KGSL_PATH/devfreq/max_freq" ]; then
    echo "1114000000" > "$KGSL_PATH/devfreq/max_freq" 2>/dev/null  # 1114 MHz ceiling
    echo "  Max freq: $(cat $KGSL_PATH/devfreq/max_freq 2>/dev/null) Hz"
fi

# 3. Increase idle_timer to keep GPU at high freq during scrolling (80-100ms)
if [ -f "$KGSL_PATH/idle_timer" ]; then
    echo "100000000" > "$KGSL_PATH/idle_timer" 2>/dev/null  # 100ms in ns
    echo "  Idle timer: $(cat $KGSL_PATH/idle_timer 2>/dev/null) ns"
fi

# 4. Allow bus and clock to power-gate during idle (cool phone, true sleep)
echo "0" > "$KGSL_PATH/force_bus_on" 2>/dev/null || true
echo "0" > "$KGSL_PATH/force_clk_on" 2>/dev/null || true
echo "  force_bus_on: $(cat $KGSL_PATH/force_bus_on 2>/dev/null)"
echo "  force_clk_on: $(cat $KGSL_PATH/force_clk_on 2>/dev/null)"

# 5. PWM/performance scaling (pwrscale) - aggressive profile
if [ -f "$KGSL_PATH/pwrscale/enable" ]; then
    echo "1" > "$KGSL_PATH/pwrscale/enable" 2>/dev/null
fi
if [ -f "$KGSL_PATH/pwrscale/busy_threshold" ]; then
    echo "30" > "$KGSL_PATH/pwrscale/busy_threshold" 2>/dev/null  # Lower = more aggressive
fi
if [ -f "$KGSL_PATH/pwrscale/idle_threshold" ]; then
    echo "10" > "$KGSL_PATH/pwrscale/idle_threshold" 2>/dev/null
fi

# 6. Devfreq tuning (alternative path)
if [ -f "$DEVFREQ_PATH/governor" ]; then
    echo "performance" > "$DEVFREQ_PATH/governor" 2>/dev/null
fi
if [ -f "$DEVFREQ_PATH/min_freq" ]; then
    echo "845000000" > "$DEVFREQ_PATH/min_freq" 2>/dev/null
fi
if [ -f "$DEVFREQ_PATH/max_freq" ]; then
    echo "1114000000" > "$DEVFREQ_PATH/max_freq" 2>/dev/null
fi

# 7. Verify
echo "=== KGSL Verification ==="
for f in governor min_freq max_freq idle_timer force_bus_on force_clk_on; do
    [ -f "$KGSL_PATH/$f" ] && echo "  $f: $(cat $KGSL_PATH/$f 2>/dev/null)"
done
for f in governor min_freq max_freq; do
    [ -f "$DEVFREQ_PATH/$f" ] && echo "  devfreq/$f: $(cat $DEVFREQ_PATH/$f 2>/dev/null)"
done
KGSL_EOF

chmod 755 /redwood/boot.d/87-kgsl-gpu-governor.sh

# ─────────────────────────────────────────────────────────────────
# 2. TOUCH IRQ AFFINITY & TOUCH BOOST - SUB-MILLISECOND RESPONSE
# ─────────────────────────────────────────────────────────────────
echo "Configuring Touch IRQ affinity to A73 cores + touch boost..."

cat > /redwood/boot.d/87-touch-irq-affinity.sh <<'TOUCH_IRQ_EOF'
#!/bin/bash
# Touch IRQ Affinity & Boost for FT3519T/Goodix @ 120Hz (8.33ms/frame)
# Pins touch interrupt to Cortex-A73 (cores 4-7) + boosts CPU on touch

# 1. Find touch IRQ (FocalTech FT3519T or Goodix)
TOUCH_IRQ=""
for irq in /proc/irq/*/; do
    name=$(cat "$irq/name" 2>/dev/null || echo "")
    if echo "$name" | grep -qiE "ft3519|focal|goodix|touch|ts_"; then
        TOUCH_IRQ=$(basename "$irq")
        echo "Found touch IRQ: $TOUCH_IRQ ($name)"
        break
    fi
done

if [ -n "$TOUCH_IRQ" ] && [ -f "/proc/irq/$TOUCH_IRQ/smp_affinity" ]; then
    # Pin to cores 4-7 (A73): bitmask 0xF0 (11110000)
    echo "f0" > "/proc/irq/$TOUCH_IRQ/smp_affinity" 2>/dev/null
    echo "  IRQ $TOUCH_IRQ affinity: $(cat /proc/irq/$TOUCH_IRQ/smp_affinity 2>/dev/null)"
fi

# Also pin backboardd and related HID threads
for irq in /proc/irq/*/; do
    name=$(cat "$irq/name" 2>/dev/null || echo "")
    if echo "$name" | grep -qiE "hid|gpio|spi.*touch|i2c.*touch"; then
        irq_num=$(basename "$irq")
        [ -f "/proc/irq/$irq_num/smp_affinity" ] && echo "f0" > "/proc/irq/$irq_num/smp_affinity" 2>/dev/null
    fi
done

# 2. Touch boost sysctls (kernel-side)
sysctl -w kern.sweet_touch_boost=1 2>/dev/null || true
sysctl -w kern.sweet_touch_boost_hold_ms=300 2>/dev/null || true
sysctl -w kern.sweet_touch_boost_freq=2800000000 2>/dev/null || true  # 2.8 GHz
sysctl -w kern.sapphire_touch_poll_interval_us=500 2>/dev/null || true
sysctl -w kern.sapphire_touch_boost_hold_ms=300 2>/dev/null || true
sysctl -w kern.sapphire_launch_boost_ms=2000 2>/dev/null || true

# 3. Set backboardd and SpringBoard to SCHED_FIFO on A73 cores via taskpolicy
if command -v taskpolicy >/dev/null 2>&1; then
    # SpringBoard main -> cores 4,5 (0x30)
    for pid in $(pgrep -x SpringBoard 2>/dev/null); do
        taskpolicy -a 0x30 -p 97 -t fifo $pid 2>/dev/null && echo "  SpringBoard($pid): A73 cores 4,5 FIFO 97"
    done
    # backboardd main -> cores 4,5
    for pid in $(pgrep -x backboardd 2>/dev/null); do
        taskpolicy -a 0x30 -p 95 -t rr $pid 2>/dev/null && echo "  backboardd($pid): A73 cores 4,5 RR 95"
    done
    # RenderServer -> all A73 (0xF0)
    for pid in $(pgrep -x RenderServer 2>/dev/null); do
        taskpolicy -a 0xF0 -p 97 -t fifo $pid 2>/dev/null && echo "  RenderServer($pid): A73 cores 4-7 FIFO 97"
    done
    # AppleCLCD -> core 4 (0x10)
    for pid in $(pgrep -x AppleCLCD 2>/dev/null); do
        taskpolicy -a 0x10 -p 98 -t fifo $pid 2>/dev/null && echo "  AppleCLCD($pid): A73 core 4 FIFO 98"
    done
fi

# 4. CPUFreq governor for A73 cluster - performance
for cpu in 4 5 6 7; do
    if [ -f "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" ]; then
        echo "performance" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null
    fi
    if [ -f "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" ]; then
        echo "2800000" > "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" 2>/dev/null
    fi
done

# 5. Verify
echo "=== Touch IRQ & Boost Verification ==="
sysctl kern.sweet_touch_boost 2>/dev/null
sysctl kern.sweet_touch_boost_hold_ms 2>/dev/null
sysctl kern.sapphire_touch_poll_interval_us 2>/dev/null
TOUCH_IRQ_EOF

chmod 755 /redwood/boot.d/87-touch-irq-affinity.sh

# ─────────────────────────────────────────────────────────────────
# 3. QUARTZCORE / RENDERSERVER - ELIMINATE BLUR & OVERDRAW STALLS
# ─────────────────────────────────────────────────────────────────
echo "Configuring aggressive CoreAnimation culling & RenderServer flags..."

cat > /redwood/boot.d/87-quartzcore-render-tuning.sh <<'CA_EOF'
#!/bin/bash
# QuartzCore / RenderServer aggressive optimization for Adreno 610
# Eliminates real-time Gaussian blur stalls, forces dirty rects, reduces layers

# 1. CoreAnimation flags (via sysctl - kernel patch 0340 provides these)
sysctl -w kern.sapphire_ca_disable_blur=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_halfres_backdrop=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_force_dirty_rects=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_shadow_quality=0 2>/dev/null || true
sysctl -w kern.sapphire_ca_max_backdrop_layers=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_color_opaque=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_reduce_transparency=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_reduce_motion=1 2>/dev/null || true

# 2. Accessibility preferences (enforced at runtime)
defaults write /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist ReduceTransparency -bool true 2>/dev/null || true
defaults write /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist ReduceMotion -bool true 2>/dev/null || true
defaults write /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist ReduceWhitePoint -bool false 2>/dev/null || true

# 3. RenderServer / DisplayLink tuning (kernel patch 0342)
sysctl -w kern.sapphire_dl_force_120hz=1 2>/dev/null || true
sysctl -w kern.sapphire_dl_adaptive_phase=1 2>/dev/null || true
sysctl -w kern.sapphire_dl_quality_hysteresis=5 2>/dev/null || true
sysctl -w kern.sapphire_dl_sysctl_cache_frames=4 2>/dev/null || true

# 4. Framebuffer pipeline - triple buffering + event-driven VSync (kernel patch 0343)
sysctl -w kern.sapphire_fb_triple_buffer=1 2>/dev/null || true
sysctl -w kern.sapphire_fb_max_inflight=3 2>/dev/null || true
sysctl -w kern.sapphire_fb_pipeline=1 2>/dev/null || true
sysctl -w kern.sapphire_fb_event_driven=1 2>/dev/null || true

# 5. GMEM & Mesa tuning (Adreno 610: 512KB GMEM) (kernel patch 0347)
sysctl -w kern.sapphire_mesa_gmem=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_glthread=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_pool=1 2>/dev/null || true
sysctl -w kern.mesa_gmem=1 2>/dev/null || true
sysctl -w kern.mesa_buffer_pool_max_mb=512 2>/dev/null || true
sysctl -w kern.mesa_shader_cache_max_mb=256 2>/dev/null || true

# 6. GPU fence adaptive sync (complements eagl.c) (kernel patch 0349)
sysctl -w kern.sweet_gpu_fence_timeout_ms=2000 2>/dev/null || true
sysctl -w kern.sweet_gpu_fence_poll_us=50 2>/dev/null || true
sysctl -w kern.sweet_gpu_async_flush=1 2>/dev/null || true
sysctl -w kern.sweet_gpu_skip_wait_threshold_us=500 2>/dev/null || true

# 7. Dynamic resolution scaling (for heavy scenes)
sysctl -w kern.sweet_fb_dyn_rscale=1 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_target=700 2>/dev/null || true  # 700K pixels target
sysctl -w kern.sweet_fb_rscale_min=500 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_max=1000 2>/dev/null || true

# 8. GPU batch settings
sysctl -w kern.gpu_batch_us=200 2>/dev/null || true
sysctl -w kern.gpu_batch_max=64 2>/dev/null || true
sysctl -w kern.gpu_shader_cache=1 2>/dev/null || true

# 9. sweetbl (native eagl.c bridge path)
sysctl -w kern.sweetbl=0 2>/dev/null || true

# 10. Verify
echo "=== QuartzCore/RenderServer Verification ==="
for sysctl in \
    kern.sapphire_ca_disable_blur \
    kern.sapphire_ca_halfres_backdrop \
    kern.sapphire_ca_force_dirty_rects \
    kern.sapphire_ca_shadow_quality \
    kern.sapphire_ca_max_backdrop_layers \
    kern.sapphire_ca_color_opaque \
    kern.sapphire_dl_force_120hz \
    kern.sapphire_fb_triple_buffer \
    kern.sapphire_fb_max_inflight \
    kern.sapphire_fb_event_driven \
    kern.sapphire_mesa_gmem \
    kern.sapphire_mesa_glthread \
    kern.sweet_gpu_fence_timeout_ms \
    kern.sweet_fb_dyn_rscale; do
    val=$(sysctl -n "$sysctl" 2>/dev/null)
    [ -n "$val" ] && echo "  $sysctl = $val"
done
CA_EOF

chmod 755 /redwood/boot.d/87-quartzcore-render-tuning.sh

# ─────────────────────────────────────────────────────────────────
# 4. CPU EAS (ENERGY AWARE SCHEDULER) - PREVENT MIGRATION TO A53
# ─────────────────────────────────────────────────────────────────
echo "Configuring CPU EAS & Scheduler for UI thread isolation on A73..."

cat > /redwood/boot.d/87-cpu-eas-scheduler.sh <<'EAS_EOF'
#!/bin/bash
# CPU EAS & Scheduler tuning - Keeps UI threads on A73, prevents migration to A53

# 1. sweet_sched=29 (custom iOS-on-Android scheduler)
sysctl -w kern.sweet_sched=29 2>/dev/null || true

# 2. AMP (Asymmetric Multi-Processing) - prefer perf cluster for UI
sysctl -w kern.sched_amp_prefer_perf=1 2>/dev/null || true

# 3. UI thread priority boost
sysctl -w kern.sched_ui_priority_boost=10 2>/dev/null || true

# 4. Reduce context switch overhead
sysctl -w kern.sched_context_switch_rate=0 2>/dev/null || true

# 5. Scheduler latency tuning
sysctl -w kern.sched_latency_ns=4000000 2>/dev/null || true      # 4ms target latency
sysctl -w kern.sched_min_granularity_ns=500000 2>/dev/null || true  # 0.5ms granularity
sysctl -w kern.sched_wakeup_granularity_ns=1000000 2>/dev/null || true # 1ms wakeup

# 6. CPU capacity scaling (ensure A73 seen as higher capacity)
# These require kernel config but try anyway
sysctl -w kern.sched_capacity_scale=1024 2>/dev/null || true

# 7. NUMA/BIG.LITTLE aware scheduling
sysctl -w kern.sched_numa_balancing=0 2>/dev/null || true  # Disable for predictable affinity

# 8. RT runtime (for SCHED_FIFO/RR threads)
sysctl -w kernel.sched_rt_runtime_us=950000 2>/dev/null || true  # 95% for RT
sysctl -w kernel.sched_rt_period_us=1000000 2>/dev/null || true

# 9. CPU idle governor - keep A73 awake
for cpu in 4 5 6 7; do
    if [ -f "/sys/devices/system/cpu/cpu$cpu/cpuidle/state0/disable" ]; then
        echo "1" > "/sys/devices/system/cpu/cpu$cpu/cpuidle/state0/disable" 2>/dev/null || true
    fi
    if [ -f "/sys/devices/system/cpu/cpu$cpu/cpuidle/state1/disable" ]; then
        echo "1" > "/sys/devices/system/cpu/cpu$cpu/cpuidle/state1/disable" 2>/dev/null || true
    fi
done

# 10. Verify
echo "=== CPU EAS/Scheduler Verification ==="
for sysctl in \
    kern.sweet_sched \
    kern.sched_amp_prefer_perf \
    kern.sched_ui_priority_boost \
    kern.sched_latency_ns \
    kern.sched_min_granularity_ns \
    kernel.sched_rt_runtime_us; do
    val=$(sysctl -n "$sysctl" 2>/dev/null)
    [ -n "$val" ] && echo "  $sysctl = $val"
done
EAS_EOF

chmod 755 /redwood/boot.d/87-cpu-eas-scheduler.sh

# ─────────────────────────────────────────────────────────────────
# 5. I/O THROTTLING & VM - ELIMINATE FS BLOCKS DURING RENDER
# ─────────────────────────────────────────────────────────────────
echo "Configuring VM & I/O for zero-render-blocking..."

cat > /redwood/boot.d/87-vm-io-tuning.sh <<'VM_IO_EOF'
#!/bin/bash
# VM & I/O tuning - Prevents dirty page writeback from blocking render thread

# 1. Dirty ratio tuning - allow more dirty pages before blocking
sysctl -w vm.dirty_ratio=40 2>/dev/null || true           # Default 20 -> 40%
sysctl -w vm.dirty_background_ratio=10 2>/dev/null || true # Default 10 -> 10% (start writeback earlier)
sysctl -w vm.dirty_expire_centisecs=3000 2>/dev/null || true # 30s vs 30s default
sysctl -w vm.dirty_writeback_centisecs=100 2>/dev/null || true # 1s vs 5s

# 2. Page free targets - keep more free for GPU allocations
sysctl -w vm.page_free_target=4000 2>/dev/null || true
sysctl -w vm.page_free_min=2000 2>/dev/null || true

# 3. Compressor tuning - more aggressive, use A53 cores
sysctl -w vm.compressor_mode=4 2>/dev/null || true        # Hybrid mode
sysctl -w vm.compressor_swapout_target_age=100 2>/dev/null || true
sysctl -w vm.compressor_threads=2 2>/dev/null || true     # Run on A53
sysctl -w vm.swapusage=0 2>/dev/null || true              # Disable swap

# 4. Speculative prefetch (helps app launch)
sysctl -w vm.speculative_prefetch_max=64 2>/dev/null || true

# 5. VFS cache pressure - prioritize inode/dentry cache
sysctl -w vm.vfs_cache_pressure=50 2>/dev/null || true    # Default 100 -> 50

# 6. Read-ahead for HFS+ (iosroot) - increase for sequential reads
block_dev="/dev/block/by-name/iosroot"
if [ -b "$block_dev" ]; then
    echo "4096" > "/sys/block/$(basename $(readlink -f $block_dev))/queue/read_ahead_kb" 2>/dev/null || true
fi

# 7. I/O scheduler - noop/none for flash storage
for disk in /sys/block/*/queue/scheduler; do
    if [ -f "$disk" ]; then
        echo "none" > "$disk" 2>/dev/null || echo "noop" > "$disk" 2>/dev/null || true
    fi
done

# 8. Verify
echo "=== VM/I/O Verification ==="
for sysctl in \
    vm.dirty_ratio \
    vm.dirty_background_ratio \
    vm.dirty_expire_centisecs \
    vm.page_free_target \
    vm.compressor_mode \
    vm.compressor_threads \
    vm.swapusage \
    vm.vfs_cache_pressure; do
    val=$(sysctl -n "$sysctl" 2>/dev/null)
    [ -n "$val" ] && echo "  $sysctl = $val"
done
VM_IO_EOF

chmod 755 /redwood/boot.d/87-vm-io-tuning.sh

# ─────────────────────────────────────────────────────────────────
# 6. MESA / FREEDRENO ENVIRONMENT - OPTIMAL ADRENO 610 CONFIG
# ─────────────────────────────────────────────────────────────────
echo "Updating Mesa environment for Adreno 610 zero-jank..."

cat > /redwood/glenv <<'GLENV_EOF'
# Mesa/freedreno environment for Adreno 610 (Snapdragon 685)
# Phase 4 Zero-Jank 120Hz - Optimal configuration

# Disable slow paths completely
FD_MESA_DEBUG=noblit,nogmem,nozwrite,noborder,nodrawpixels,noinvalidate

# Performance hints
FD_PERF=1

# Shader cache (256MB for 120Hz sustained)
MESA_SHADER_CACHE_MAX_SIZE_MB=256
MESA_GLSL_CACHE_DISABLE=false

# Buffer pool (512MB for triple buffering + headroom)
MESA_BUFFER_POOL_MAX_MB=512

# Disable debug overhead
IR3_SHADER_DEBUG=0
FD_MESA_DEBUG_SPARSE=0

# GMEM configuration (Adreno 610: ~512KB GMEM)
# Force GMEM path for tile-based rendering with explicit tile parameters
FD_GMEM=1
FD_GMEM_TILE_WIDTH=256
FD_GMEM_TILE_HEIGHT=256
FD_GMEM_NUM_TILES=4
FD_GMEM_MAX_SIZE=524288

# Threading - CRITICAL for decoupling render/submit
MESA_GLTHREAD=1

# Async flush (prevents CPU stall on GPU fence)
FD_ASYNC_FLUSH=1

# Disable sync points (use explicit fences instead)
FD_NO_SYNC=1

# Precision hints - mediump saves bandwidth
MESA_GLSL_PRECISION=mediump

# Zero-copy IOSurface
FD_IOSURFACE_ZERO_COPY=1

# Turnip/Zink specific (if used)
TU_DEBUG=noconform
ZINK_DEBUG=quiet

# Limit max in-flight frames (triple buffer)
sweet_fb_max_inflight=3

# Dynamic resolution scale
sweet_fb_dyn_rscale=1
sweet_fb_rscale_target=700

# Event-driven VSync
sweet_fb_event_driven=1
GLENV_EOF

# Persist to all known locations
cp /redwood/glenv /var/tmp/gl.env 2>/dev/null || true
cp /redwood/glenv /private/var/tmp/gl.env 2>/dev/null || true
cp /redwood/glenv /redwood/glenv 2>/dev/null || true

# Also write gl.args for immediate effect
printf "vblur=0 glwait=1 glprecision=0 glthread=1 async=1" > /var/tmp/gl.args 2>/dev/null || true
printf "vblur=0 glwait=1 glprecision=0 glthread=1 async=1" > /private/var/tmp/gl.args 2>/dev/null || true
printf "vblur=0 glwait=1 glprecision=0 glthread=1 async=1" > /redwood/gl.args 2>/dev/null || true
chmod 666 /var/tmp/gl.args /private/var/tmp/gl.args /redwood/gl.args 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────
# 7. KERNEL PATCHES FOR PHASE 4 (STAGED FOR NEXT KERNEL BUILD)
# ─────────────────────────────────────────────────────────────────
echo "Staging kernel patches for Phase 4..."

mkdir -p /redwood/patches

# 0346: CoreAnimation blur disable sysctls
cat > /redwood/patches/0346-sapphire-ca-blur-disable.patch <<'CA_PATCH_EOF'
--- a/bsd/kern/sysctl_ca.c
+++ b/bsd/kern/sysctl_ca.c
@@ -0,0 +1,120 @@
+/*
+ * 0346-sapphire-ca-blur-disable.patch
+ * CoreAnimation blur/shadow disable sysctls for Adreno 610
+ */
+#if defined(ARM64_BOARD_CONFIG_SWEET)
+#include <sys/sysctl.h>
+#include <sys/param.h>
+
+static int sapphire_ca_disable_blur = 1;
+static int sapphire_ca_halfres_backdrop = 1;
+static int sapphire_ca_force_dirty_rects = 1;
+static int sapphire_ca_shadow_quality = 0;
+static int sapphire_ca_max_backdrop_layers = 1;
+static int sapphire_ca_color_opaque = 1;
+static int sapphire_ca_reduce_transparency = 1;
+static int sapphire_ca_reduce_motion = 1;
+
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_disable_blur,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_disable_blur, 0,
+    "Disable CoreAnimation backdrop blur (1=disable)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_halfres_backdrop,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_halfres_backdrop, 0,
+    "Render backdrop at half resolution (1=enable)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_force_dirty_rects,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_force_dirty_rects, 0,
+    "Force dirty rect rendering (1=enable)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_shadow_quality,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_shadow_quality, 0,
+    "Shadow quality (0=none, 1=low, 2=medium, 3=high)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_max_backdrop_layers,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_max_backdrop_layers, 0,
+    "Maximum simultaneous backdrop layers");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_color_opaque,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_color_opaque, 0,
+    "Treat all layers as opaque (skip alpha blending)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_reduce_transparency,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_reduce_transparency, 0,
+    "Reduce system transparency effects");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_ca_reduce_motion,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_ca_reduce_motion, 0,
+    "Reduce system motion effects");
+#endif
CA_PATCH_EOF

# 0347: DisplayLink 120Hz promotion sysctls
cat > /redwood/patches/0347-sapphire-dl-120hz.patch <<'DL_PATCH_EOF'
--- a/bsd/kern/sysctl_dl.c
+++ b/bsd/kern/sysctl_dl.c
@@ -0,0 +1,100 @@
+/*
+ * 0347-sapphire-dl-120hz.patch
+ * DisplayLink 120Hz promotion & frame pacing sysctls
+ */
+#if defined(ARM64_BOARD_CONFIG_SWEET)
+#include <sys/sysctl.h>
+
+static int sapphire_dl_force_120hz = 1;
+static int sapphire_dl_adaptive_phase = 1;
+static int sapphire_dl_quality_hysteresis = 5;
+static int sapphire_dl_sysctl_cache_frames = 4;
+
+SYSCTL_INT(_kern, OID_AUTO, sapphire_dl_force_120hz,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_dl_force_120hz, 0,
+    "Force CADisplayLink 120Hz promotion");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_dl_adaptive_phase,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_dl_adaptive_phase, 0,
+    "Adaptive phase prediction (EMA)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_dl_quality_hysteresis,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_dl_quality_hysteresis, 0,
+    "Quality reduction hysteresis (frames)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_dl_sysctl_cache_frames,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_dl_sysctl_cache_frames, 0,
+    "Sysctl cache refresh interval (frames)");
+#endif
DL_PATCH_EOF

# 0348: Framebuffer pipeline sysctls
cat > /redwood/patches/0348-sapphire-fb-pipeline.patch <<'FB_PATCH_EOF'
--- a/bsd/kern/sysctl_fb.c
+++ b/bsd/kern/sysctl_fb.c
@@ -0,0 +1,110 @@
+/*
+ * 0348-sapphire-fb-pipeline.patch
+ * Framebuffer pipeline: triple buffer, event-driven VSync, dyn rscale
+ */
+#if defined(ARM64_BOARD_CONFIG_SWEET)
+#include <sys/sysctl.h>
+
+static int sapphire_fb_triple_buffer = 1;
+static int sapphire_fb_max_inflight = 3;
+static int sapphire_fb_pipeline = 1;
+static int sapphire_fb_event_driven = 1;
+static int sweet_fb_dyn_rscale = 1;
+static int sweet_fb_rscale_target = 700;
+static int sweet_fb_rscale_min = 500;
+static int sweet_fb_rscale_max = 1000;
+static int sweet_gpu_fence_timeout_ms = 2000;
+static int sweet_gpu_fence_poll_us = 50;
+static int sweet_gpu_async_flush = 1;
+static int sweet_gpu_skip_wait_threshold_us = 500;
+static int sweetbl = 1;
+
+SYSCTL_INT(_kern, OID_AUTO, sapphire_fb_triple_buffer,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_fb_triple_buffer, 0,
+    "Enable triple buffering");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_fb_max_inflight,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_fb_max_inflight, 0,
+    "Max in-flight frames (2=double, 3=triple)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_fb_pipeline,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_fb_pipeline, 0,
+    "Enable pipelined frame submission");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_fb_event_driven,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_fb_event_driven, 0,
+    "Event-driven VSync wait (vs polling)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_fb_dyn_rscale,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_fb_dyn_rscale, 0,
+    "Dynamic resolution scaling enable");
+SYSCTL_INT(_kern, OID_AUTO, sweet_fb_rscale_target,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_fb_rscale_target, 0,
+    "Target pixel count for dyn rscale (thousands)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_fb_rscale_min,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_fb_rscale_min, 0,
+    "Minimum pixel count for dyn rscale (thousands)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_fb_rscale_max,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_fb_rscale_max, 0,
+    "Maximum pixel count for dyn rscale (thousands)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_gpu_fence_timeout_ms,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_gpu_fence_timeout_ms, 0,
+    "GPU fence timeout (ms)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_gpu_fence_poll_us,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_gpu_fence_poll_us, 0,
+    "GPU fence poll interval (us)");
+SYSCTL_INT(_kern, OID_AUTO, sweet_gpu_async_flush,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_gpu_async_flush, 0,
+    "Async GPU flush enable");
+SYSCTL_INT(_kern, OID_AUTO, sweet_gpu_skip_wait_threshold_us,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweet_gpu_skip_wait_threshold_us, 0,
+    "Skip glClientWaitSync if wait < threshold (us)");
+SYSCTL_INT(_kern, OID_AUTO, sweetbl,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sweetbl, 0,
+    "Sweet backlight fast path");
+#endif
FB_PATCH_EOF

# 0349: Mesa/GMEM sysctls
cat > /redwood/patches/0349-sapphire-mesa-gmem.patch <<'MESA_PATCH_EOF'
--- a/bsd/kern/sysctl_mesa.c
+++ b/bsd/kern/sysctl_mesa.c
@@ -0,0 +1,80 @@
+/*
+ * 0349-sapphire-mesa-gmem.patch
+ * Mesa/freedreno GMEM & threading sysctls
+ */
+#if defined(ARM64_BOARD_CONFIG_SWEET)
+#include <sys/sysctl.h>
+
+static int sapphire_mesa_gmem = 1;
+static int sapphire_mesa_glthread = 1;
+static int sapphire_mesa_pool = 1;
+static int mesa_gmem = 1;
+static int mesa_buffer_pool_max_mb = 512;
+static int mesa_shader_cache_max_mb = 256;
+static int gpu_batch_us = 200;
+static int gpu_batch_max = 64;
+static int gpu_shader_cache = 1;
+
+SYSCTL_INT(_kern, OID_AUTO, sapphire_mesa_gmem,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_mesa_gmem, 0,
+    "Enable Mesa GMEM path");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_mesa_glthread,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_mesa_glthread, 0,
+    "Enable Mesa GL threading (render/submit decouple)");
+SYSCTL_INT(_kern, OID_AUTO, sapphire_mesa_pool,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &sapphire_mesa_pool, 0,
+    "Enable Mesa buffer pool");
+SYSCTL_INT(_kern, OID_AUTO, mesa_gmem,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &mesa_gmem, 0,
+    "Mesa GMEM enable");
+SYSCTL_INT(_kern, OID_AUTO, mesa_buffer_pool_max_mb,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &mesa_buffer_pool_max_mb, 0,
+    "Mesa buffer pool max size (MB)");
+SYSCTL_INT(_kern, OID_AUTO, mesa_shader_cache_max_mb,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &mesa_shader_cache_max_mb, 0,
+    "Mesa shader cache max size (MB)");
+SYSCTL_INT(_kern, OID_AUTO, gpu_batch_us,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &gpu_batch_us, 0,
+    "GPU batch submission interval (us)");
+SYSCTL_INT(_kern, OID_AUTO, gpu_batch_max,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &gpu_batch_max, 0,
+    "GPU batch max commands");
+SYSCTL_INT(_kern, OID_AUTO, gpu_shader_cache,
+    CTLFLAG_RW | CTLFLAG_LOCKED, &gpu_shader_cache, 0,
+    "GPU shader cache enable");
+#endif
MESA_PATCH_EOF

# ─────────────────────────────────────────────────────────────────
# 8. VERIFICATION
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== [87] Phase 4 Zero-Jank Verification ==="

echo "Boot.d scripts:"
for script in \
    87-kgsl-gpu-governor.sh \
    87-touch-irq-affinity.sh \
    87-quartzcore-render-tuning.sh \
    87-cpu-eas-scheduler.sh \
    87-vm-io-tuning.sh; do
    if [ -f "/redwood/boot.d/$script" ]; then
        echo "  ✓ $script"
    else
        echo "  ✗ $script MISSING"
    fi
done

echo ""
echo "Mesa environment:"
[ -f /redwood/glenv ] && echo "  ✓ glenv" || echo "  ✗ glenv missing"
[ -f /var/tmp/gl.args ] && echo "  ✓ gl.args" || echo "  ✗ gl.args missing"

echo ""
echo "Kernel patches staged:"
for patch in \
    0346-sapphire-ca-blur-disable.patch \
    0347-sapphire-dl-120hz.patch \
    0348-sapphire-fb-pipeline.patch \
    0349-sapphire-mesa-gmem.patch; do
    if [ -f "/redwood/patches/$patch" ]; then
        echo "  ✓ $patch"
    else
        echo "  ✗ $patch missing"
    fi
done

echo ""
echo "=== [87] Phase 4 Zero-Jank Ultra Fluidity COMPLETE ==="
echo "Next: Update 76-master-fix-installer.sh and build v0.5.0"
true