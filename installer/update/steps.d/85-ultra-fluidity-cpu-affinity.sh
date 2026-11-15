#!/bin/bash
# 85-ultra-fluidity-cpu-affinity.sh: Phase 3 Ultimate Fluidity Optimization
# Targets: 90-120 FPS stable on Redmi Note 13 4G (SM6225/Adreno 610)
# Architecture: Pure iOS/XNU/launchd

set -e

echo "=== [85] Phase 3 Ultra Fluidity: CPU Affinity + VSync Interrupt + Mesa Tuning ==="

# ─────────────────────────────────────────────────────────────────
# 1. CPU CORE AFFINITY PINNING (SM6225: A73×4 @ 2.8GHz cores 4-7, A53×4 @ 1.9GHz cores 0-3)
# ─────────────────────────────────────────────────────────────────
echo "Configuring CPU affinity for critical processes..."

cat > /redwood/bin/set-cpu-affinity.sh <<'AFFINITY_EOF'
#!/bin/bash
# set-cpu-affinity.sh: Pins critical iOS processes to A73 performance cores (4-7)
# Uses task_policy_set with TASK_POLICY_AFFINITY (requires root)

# Core mapping for SM6225 (Snapdragon 685):
# CPU 0-3: Cortex-A53 (Silver/efficiency) @ 1.9 GHz
# CPU 4-7: Cortex-A73 (Gold/performance) @ 2.8 GHz

# Affinity masks (bitmask of allowed CPUs)
A73_MASK=0xF0  # cores 4,5,6,7 (11110000)
A73_CORE45_MASK=0x30  # cores 4,5 (00110000)
A73_CORE67_MASK=0xC0  # cores 6,7 (11000000)
A53_MASK=0x0F  # cores 0,1,2,3 (00001111)

# Helper: set affinity for PID
set_affinity() {
    local pid=$1
    local mask=$2
    local policy=$3  # FIFO, RR, OTHER
    local priority=$4

    # Use taskpolicy if available (macOS/iOS)
    if command -v taskpolicy >/dev/null 2>&1; then
        case $policy in
            FIFO) taskpolicy -a $mask -p $priority -t fifo $pid 2>/dev/null ;;
            RR)   taskpolicy -a $mask -p $priority -t rr $pid 2>/dev/null ;;
            *)    taskpolicy -a $mask $pid 2>/dev/null ;;
        esac
    fi

    # Fallback: sysctl (if kernel supports it)
    sysctl -w kern.sched_affinity_$pid=$mask 2>/dev/null || true
}

# Apply affinity to running processes
apply_affinity() {
    echo "[CPU Affinity] Applying core pinning..."

    # SpringBoard (main thread) → cores 4,5 (A73)
    for pid in $(pgrep -x SpringBoard); do
        set_affinity $pid $A73_CORE45_MASK FIFO 97
    done

    # SpringBoard render threads → cores 6,7 (A73)
    # Note: Need to identify render threads - use thread affinity if possible
    for pid in $(pgrep -f "SpringBoard.*render"); do
        set_affinity $pid $A73_CORE67_MASK FIFO 96
    done

    # backboardd (main) → cores 4,5 (A73)
    for pid in $(pgrep -x backboardd); do
        set_affinity $pid $A73_CORE45_MASK RR 95
    done

    # backboardd (HID/touch) → cores 6,7 (A73)
    for pid in $(pgrep -f "backboardd.*HID"); do
        set_affinity $pid $A73_CORE67_MASK RR 94
    done

    # RenderServer → cores 4-7 (all A73)
    for pid in $(pgrep -x RenderServer); do
        set_affinity $pid $A73_MASK FIFO 97
    done

    # AppleCLCD (display controller) → core 4 (A73)
    for pid in $(pgrep -x AppleCLCD); do
        set_affinity $pid 0x10 FIFO 98  # core 4 only
    done

    # mediaserverd → cores 0-3 (A53)
    for pid in $(pgrep -x mediaserverd); do
        set_affinity $pid $A53_MASK OTHER 20
    done

    # WindowServer (if exists) → cores 4-7
    for pid in $(pgrep -x WindowServer); do
        set_affinity $pid $A73_MASK FIFO 96
    done

    echo "[CPU Affinity] Done"
}

# Run once at boot - no polling loop needed
# Critical processes (SpringBoard, backboardd, RenderServer) are long-lived
# New processes inherit scheduler defaults; kernel patch 0345 provides affinity sysctl
apply_affinity
AFFINITY_EOF

chmod 755 /redwood/bin/set-cpu-affinity.sh

# Launchd job for CPU affinity (runs once at boot, no KeepAlive)
cat > /redwood/launchd/com.sapphire.cpu-affinity.plist <<'AFFINITY_PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sapphire.cpu-affinity</string>
    <key>ProgramArguments</key>
    <array>
        <string>/redwood/bin/set-cpu-affinity.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>UserName</key>
    <string>root</string>
    <key>GroupName</key>
    <string>wheel</string>
    <key>StandardOutPath</key>
    <string>/var/tmp/cpu-affinity.log</string>
    <key>StandardErrorPath</key>
    <string>/var/tmp/cpu-affinity.log</string>
</dict>
</plist>
AFFINITY_PLIST_EOF

# ─────────────────────────────────────────────────────────────────
# 2. KERNEL PATCH: CPU AFFINITY SYSCALL SUPPORT (0348)
# ─────────────────────────────────────────────────────────────────
echo "Creating kernel patch for CPU affinity syscall..."

mkdir -p /redwood/patches
cat > /redwood/patches/0348-sapphire-cpu-affinity.patch <<'PATCH_EOF'
--- a/bsd/kern/sched_affinity.c
+++ b/bsd/kern/sched_affinity.c
@@ -0,0 +1,180 @@
+/*
+ * 0348-sapphire-cpu-affinity.patch
+ * CPU Affinity syscall support for SM6225 (A73/A53 big.LITTLE)
+ * Allows userspace to pin threads to performance cores
+ */
+#if defined(ARM64_BOARD_CONFIG_SWEET)
+#include <sys/param.h>
+#include <sys/systm.h>
+#include <sys/proc.h>
+#include <sys/sysctl.h>
+#include <sys/sysproto.h>
+#include <kern/thread.h>
+#include <kern/sched_prim.h>
+#include <kern/affinity.h>
+
+/*
+ * CPU topology for SM6225:
+ * Cluster 0 (Silver): CPU 0-3, Cortex-A53 @ 1.9 GHz
+ * Cluster 1 (Gold):   CPU 4-7, Cortex-A73 @ 2.8 GHz
+ */
+static const uint32_t sapphire_a73_mask = 0xF0;  // CPU 4-7
+static const uint32_t sapphire_a53_mask = 0x0F;  // CPU 0-3
+
+/* Affinity policy tags */
+#define SAPHIRE_AFFINITY_A73      1  // Performance cores
+#define SAPHIRE_AFFINITY_A53      2  // Efficiency cores
+#define SAPHIRE_AFFINITY_ANY      3  // No restriction
+#define SAPHIRE_AFFINITY_CUSTOM   4  // Custom mask
+
+static int
+sapphire_thread_affinity_set(thread_t thread, uint32_t policy, uint32_t custom_mask)
+{
+    uint32_t affinity_mask = 0;
+    boolean_t is_fixed = FALSE;
+
+    switch (policy) {
+        case SAPHIRE_AFFINITY_A73:
+            affinity_mask = sapphire_a73_mask;
+            is_fixed = TRUE;
+            break;
+        case SAPHIRE_AFFINITY_A53:
+            affinity_mask = sapphire_a53_mask;
+            is_fixed = TRUE;
+            break;
+        case SAPHIRE_AFFINITY_ANY:
+            affinity_mask = sapphire_a73_mask | sapphire_a53_mask;
+            is_fixed = FALSE;
+            break;
+        case SAPHIRE_AFFINITY_CUSTOM:
+            affinity_mask = custom_mask & (sapphire_a73_mask | sapphire_a53_mask);
+            is_fixed = (affinity_mask != 0);
+            break;
+        default:
+            return EINVAL;
+    }
+
+    if (is_fixed) {
+        thread_affinity_set(thread, affinity_mask);
+        thread_bind(thread, TH_BIND_FIXED);
+    } else {
+        thread_bind(thread, TH_BIND_NONE);
+    }
+
+    return 0;
+}
+
+/* Sysctl: kern.sapphire_affinity_<pid> = <policy> [custom_mask] */
+static int
+sysctl_sapphire_affinity SYSCTL_HANDLER_ARGS
+{
+#pragma unused(oidp, arg1, arg2)
+    int error = 0;
+    int request[2];
+    size_t len = sizeof(request);
+
+    if (req->oldptr == USER_ADDR_NULL) {
+        return sysctl_handle_int(oidp, NULL, 0, req);
+    }
+
+    error = SYSCTL_IN(req, request, len);
+    if (error) return error;
+
+    pid_t pid = request[0];
+    int policy = request[1];
+    uint32_t custom_mask = (len > 8) ? request[2] : 0;
+
+    proc_t p = proc_find(pid);
+    if (p == PROC_NULL) return ESRCH;
+
+    thread_t thread = NULL;
+    thread_array_t threads = NULL;
+    mach_msg_type_number_t thread_count = 0;
+
+    task_threads(p->task, &threads, &thread_count);
+    if (thread_count > 0) {
+        thread = threads[0];  // Main thread
+        sapphire_thread_affinity_set(thread, policy, custom_mask);
+    }
+
+    if (threads) {
+        vm_deallocate(kernel_map, (vm_offset_t)threads, thread_count * sizeof(thread_t));
+    }
+    proc_rele(p);
+
+    return 0;
+}
+
+SYSCTL_PROC(_kern, OID_AUTO, sapphire_affinity,
+    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED | CTLFLAG_ANYBODY,
+    0, 0, sysctl_sapphire_affinity, "I", "Set thread CPU affinity (pid, policy, mask)");
+
+/* Boot-time default affinity for known processes */
+static void
+sapphire_apply_default_affinity(void)
+{
+    /* These run at boot via launchd, but we can set kernel defaults here */
+    /* Actual application happens in userspace via set-cpu-affinity.sh */
+}
+
+#endif /* ARM64_BOARD_CONFIG_SWEET */
PATCH_EOF

# ─────────────────────────────────────────────────────────────────
# 3. VSYNC INTERRUPT-DRIVEN FRAME PACING (Kernel Patch 0344)
# ─────────────────────────────────────────────────────────────────
echo "Creating kernel patch for VSync interrupt-driven flip completion..."

cat > /redwood/patches/0344-sapphire-vsync-interrupt.patch <<'VSYNC_PATCH_EOF'
--- a/iokit/IOGraphics/IOFramebuffer.cpp
+++ b/iokit/IOGraphics/IOFramebuffer.cpp
@@ -1200,6 +1200,85 @@
+/*
+ * 0344-sapphire-vsync-interrupt.patch
+ * Event-driven flip completion via hardware VSync interrupt
+ * Replaces IOTimerEventSource polling (IODelay) with thread_wakeup
+ */
+
+/* Sweet Framebuffer VSync interrupt handler */
+class SweetVSyncHandler : public OSObject {
+    OSDeclareDefaultStructors(SweetVSyncHandler)
+
+private:
+    IOTimerEventSource *timer_source;
+    thread_t present_thread;
+    uint64_t last_vsync_ts;
+    uint32_t vsync_interval_ns;  // 8333333 for 120Hz
+    bool event_driven_enabled;
+
+public:
+    static SweetVSyncHandler *withFramebuffer(IOFramebuffer *fb);
+    virtual bool init(IOFramebuffer *fb);
+    virtual void free();
+
+    /* Called from DSI interrupt context (AppleCLCD) */
+    void vsyncInterrupt(uint64_t timestamp);
+
+    /* Called by present thread to wait for next VSync */
+    IOReturn waitForVSync(uint64_t deadline_ns);
+
+    /* Enable/disable event-driven mode */
+    void setEventDriven(bool enable);
+};
+
+bool
+SweetVSyncHandler::init(IOFramebuffer *fb)
+{
+    if (!super::init()) return false;
+
+    vsync_interval_ns = 8333333;  // 120Hz default
+    event_driven_enabled = false;
+    present_thread = THREAD_NULL;
+    last_vsync_ts = 0;
+
+    /* Check boot-arg for event-driven mode */
+    event_driven_enabled = PE_parse_boot_argn("sweet_fb_event_driven", NULL, 0);
+
+    return true;
+}
+
+void
+SweetVSyncHandler::free()
+{
+    if (timer_source) {
+        timer_source->cancelTimeout();
+        timer_source->release();
+        timer_source = NULL;
+    }
+    super::free();
+}
+
+void
+SweetVSyncHandler::vsyncInterrupt(uint64_t timestamp)
+{
+    last_vsync_ts = timestamp;
+
+    if (event_driven_enabled && present_thread != THREAD_NULL) {
+        /* Wake up present thread immediately - NO POLLING */
+        thread_wakeup((event_t)&present_thread, THREAD_AWAKENED, FALSE);
+        present_thread = THREAD_NULL;
+    }
+}
+
+IOReturn
+SweetVSyncHandler::waitForVSync(uint64_t deadline_ns)
+{
+    if (!event_driven_enabled) {
+        /* Fallback: legacy timer-based wait */
+        return kIOReturnUnsupported;
+    }
+
+    present_thread = current_thread();
+
+    /* Calculate timeout based on deadline */
+    uint64_t now = mach_absolute_time();
+    uint64_t timeout_ns = (deadline_ns > now) ? (deadline_ns - now) : 1000000;
+
+    /* Convert to abstime for thread_block */
+    uint64_t abstime = 0;
+    nanoseconds_to_absolutetime(timeout_ns, &abstime);
+
+    /* Block until VSync interrupt wakes us */
+    thread_block(THREAD_BLOCK_CONTINUE);
+
+    /* Verify we woke up close to VSync */
+    uint64_t wake_ts = mach_absolute_time();
+    uint64_t latency_ns = (wake_ts > last_vsync_ts) ? (wake_ts - last_vsync_ts) : 0;
+
+    if (latency_ns > 2000000) {  // >2ms latency = missed frame
+        return kIOReturnTimeout;
+    }
+
+    return kIOReturnSuccess;
+}
+
+void
+SweetVSyncHandler::setEventDriven(bool enable)
+{
+    event_driven_enabled = enable;
+}
+
+SweetVSyncHandler *
+SweetVSyncHandler::withFramebuffer(IOFramebuffer *fb)
+{
+    SweetVSyncHandler *handler = new SweetVSyncHandler;
+    if (handler && handler->init(fb)) {
+        return handler;
+    }
+    if (handler) handler->release();
+    return NULL;
+}
+
 /* IOFramebuffer additions */

 class IOFramebuffer : public IOService {
@@ -1350,6 +1429,15 @@
     SweetVSyncHandler *sweet_vsync;

     virtual void sweetVSyncInterrupt(uint64_t timestamp);
+
+    /* Override present to use event-driven VSync wait */
+    virtual IOReturn presentSurface(IOOptionBits options, IOFramebufferCompletion completion,
+                                    void *completionTarget, IOFramebufferCompletion completionRef);
 };

 void
 IOFramebuffer::sweetVSyncInterrupt(uint64_t timestamp)
 {
     if (sweet_vsync) {
         sweet_vsync->vsyncInterrupt(timestamp);
     }
 }

 IOReturn
 IOFramebuffer::presentSurface(IOOptionBits options, IOFramebufferCompletion completion,
                               void *completionTarget, IOFramebufferCompletion completionRef)
 {
     if (sweet_vsync && sweet_vsync->isEventDriven()) {
         /* Calculate next VSync deadline */
         uint64_t now = mach_absolute_time();
         uint64_t deadline = now + sweet_vsync->getVSyncInterval();

         IOReturn ret = sweet_vsync->waitForVSync(deadline);
         if (ret != kIOReturnSuccess) {
             /* Missed frame - log and continue */
             IOLog("SweetVSync: missed frame deadline, latency=%llu ns\n", ret);
         }

         /* Call original present */
         return super::presentSurface(options, completion, completionTarget, completionRef);
     }

     return super::presentSurface(options, completion, completionTarget, completionRef);
 }
VSYNC_PATCH_EOF

# ─────────────────────────────────────────────────────────────────
# 4. ADRENO 610 MESA TUNING (Environment Variables)
# ─────────────────────────────────────────────────────────────────
echo "Updating Mesa environment for Adreno 610 optimal performance..."

cat > /redwood/glenv <<'GLENV_EOF'
# Mesa/freedreno environment for Adreno 610 (Snapdragon 685)
# Optimized for 120Hz fluidity on iOS 16.7.16

# Disable slow paths
FD_MESA_DEBUG=noblit,nogmem,nozwrite,noborder

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

# GMEM configuration (Adreno 610: 512KB GMEM)
# Force GMEM path for tile-based rendering with explicit tile parameters
FD_GMEM=1
FD_GMEM_TILE_WIDTH=256
FD_GMEM_TILE_HEIGHT=256
FD_GMEM_NUM_TILES=4
FD_GMEM_MAX_SIZE=524288

# Threading
MESA_GLTHREAD=1

# Async flush (prevents CPU stall on GPU)
FD_ASYNC_FLUSH=1

# Disable sync points (use explicit fences instead)
FD_NO_SYNC=1

# Precision hints
MESA_GLSL_PRECISION=mediump

# Zero-copy IOSurface
FD_IOSURFACE_ZERO_COPY=1
GLENV_EOF

# Also persist to all known locations
cp /redwood/glenv /var/tmp/gl.env 2>/dev/null || true
cp /redwood/glenv /private/var/tmp/gl.env 2>/dev/null || true
cp /redwood/glenv /redwood/glenv 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────
# 5. COREANIMATION AGGRESSIVE CULLING (Boot Args)
# ─────────────────────────────────────────────────────────────────
echo "Setting aggressive CoreAnimation culling boot args..."

# These are appended to existing boot args in 58-sapphire-boot-args.sh
cat > /redwood/boot.d/85-ca-aggressive-culling.sh <<'CA_EOF'
#!/bin/bash
# Aggressive CoreAnimation culling for 120Hz

# Color opaque - skip alpha blending entirely
sysctl -w kern.sapphire_ca_color_opaque=1 2>/dev/null || true

# Shadow quality = 0 (no shadows)
sysctl -w kern.sapphire_ca_shadow_quality=0 2>/dev/null || true

# Max backdrop layers = 1 (single backdrop only)
sysctl -w kern.sapphire_ca_max_backdrop_layers=1 2>/dev/null || true

# Force dirty rects (partial updates only)
sysctl -w kern.sapphire_ca_force_dirty_rects=1 2>/dev/null || true

# Reduce transparency/motion (accessibility keys)
defaults write /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist ReduceTransparency -bool true 2>/dev/null || true
defaults write /private/var/mobile/Library/Preferences/com.apple.Accessibility.plist ReduceMotion -bool true 2>/dev/null || true

# Verify
echo "CA Culling: color_opaque=$(sysctl -n kern.sapphire_ca_color_opaque 2>/dev/null) shadow_quality=$(sysctl -n kern.sapphire_ca_shadow_quality 2>/dev/null) max_backdrops=$(sysctl -n kern.sapphire_ca_max_backdrop_layers 2>/dev/null) force_dirty=$(sysctl -n kern.sapphire_ca_force_dirty_rects 2>/dev/null)"
CA_EOF

chmod 755 /redwood/boot.d/85-ca-aggressive-culling.sh

# ─────────────────────────────────────────────────────────────────
# 6. TOUCH RESPONSE OPTIMIZATION (FT3519T)
# ─────────────────────────────────────────────────────────────────
echo "Optimizing touch response (FT3519T, 250Hz polling)..."

cat > /redwood/boot.d/85-touch-optimization.sh <<'TOUCH_EOF'
#!/bin/bash
# Touch optimization for FT3519T

# IRQ-paced polling interval (0.5ms = 2000Hz theoretical, but 250Hz while finger down)
sysctl -w kern.sapphire_touch_poll_interval_us=500 2>/dev/null || true

# Touch boost hold (300ms after lift)
sysctl -w kern.sapphire_touch_boost_hold_ms=300 2>/dev/null || true

# App launch boost (2000ms)
sysctl -w kern.sapphire_launch_boost_ms=2000 2>/dev/null || true

# Sweet touch boost (affinity to A73 during touch)
sysctl -w kern.sweet_touch_boost=1 2>/dev/null || true

# Verify
echo "Touch: poll_interval=$(sysctl -n kern.sapphire_touch_poll_interval_us 2>/dev/null) boost_hold=$(sysctl -n kern.sapphire_touch_boost_hold_ms 2>/dev/null) launch_boost=$(sysctl -n kern.sapphire_launch_boost_ms 2>/dev/null)"
TOUCH_EOF

chmod 755 /redwood/boot.d/85-touch-optimization.sh

# ─────────────────────────────────────────────────────────────────
# 7. VM COMPRESSOR & MEMORY PRESSURE TUNING
# ─────────────────────────────────────────────────────────────────
echo "Tuning VM compressor for sustained 120Hz..."

cat > /redwood/boot.d/85-vm-compressor.sh <<'VM_EOF'
#!/bin/bash
# VM Compressor tuning for sustained fluidity

# More aggressive compression (trade CPU for memory)
sysctl -w vm.compressor_mode=4 2>/dev/null || true  # VM_PAGER_COMPRESSOR_MODE_HYBRID

# Lower swap threshold - keep more in compressed memory
sysctl -w vm.compressor_swapout_target_age=100 2>/dev/null || true

# Increase compressor worker threads (use A53 cores)
sysctl -w vm.compressor_threads=2 2>/dev/null || true

# Page free target (keep more free pages for GPU allocations)
sysctl -w vm_page_free_target=4000 2>/dev/null || true
sysctl -w vm_page_free_min=2000 2>/dev/null || true

# Speculative prefetch (helps SpringBoard launch)
sysctl -w vm.speculative_prefetch_max=64 2>/dev/null || true

# Disable swap entirely (we have 6-8GB RAM)
sysctl -w vm.swapusage=0 2>/dev/null || true

echo "VM: compressor_mode=$(sysctl -n vm.compressor_mode 2>/dev/null) threads=$(sysctl -n vm.compressor_threads 2>/dev/null) free_target=$(sysctl -n vm_page_free_target 2>/dev/null)"
VM_EOF

chmod 755 /redwood/boot.d/85-vm-compressor.sh

# ─────────────────────────────────────────────────────────────────
# 8. DISPLAYLINK 120HZ PROMOTION & FRAME PACING
# ─────────────────────────────────────────────────────────────────
echo "Configuring DisplayLink 120Hz promotion..."

cat > /redwood/boot.d/85-displaylink-120hz.sh <<'DL_EOF'
#!/bin/bash
# DisplayLink 120Hz promotion and frame pacing

# Force 120Hz CADisplayLink promotion
sysctl -w kern.sapphire_dl_force_120hz=1 2>/dev/null || true

# Adaptive phase prediction (EMA)
sysctl -w kern.sapphire_dl_adaptive_phase=1 2>/dev/null || true

# Quality reduction hysteresis (5 consecutive misses/good)
sysctl -w kern.sapphire_dl_quality_hysteresis=5 2>/dev/null || true

# Cached sysctl reads (every 4 frames)
sysctl -w kern.sapphire_dl_sysctl_cache_frames=4 2>/dev/null || true

# Triple buffering enable
sysctl -w kern.sapphire_fb_triple_buffer=1 2>/dev/null || true

# Max in-flight frames
sysctl -w kern.sapphire_fb_max_inflight=3 2>/dev/null || true

# Pipeline enable
sysctl -w kern.sapphire_fb_pipeline=1 2>/dev/null || true

echo "DL: force120=$(sysctl -n kern.sapphire_dl_force_120hz 2>/dev/null) adaptive=$(sysctl -n kern.sapphire_dl_adaptive_phase 2>/dev/null) hysteresis=$(sysctl -n kern.sapphire_dl_quality_hysteresis 2>/dev/null)"
DL_EOF

chmod 755 /redwood/boot.d/85-displaylink-120hz.sh

# ─────────────────────────────────────────────────────────────────
# 9. SCHEDULER TUNING (sweet_sched=29)
# ─────────────────────────────────────────────────────────────────
echo "Applying scheduler tuning (sweet_sched=29)..."

cat > /redwood/boot.d/85-scheduler-tuning.sh <<'SCHED_EOF'
#!/bin/bash
# Scheduler tuning for fluidity

# sweet_sched=29: Custom scheduler for iOS on Android hardware
# Prioritizes UI threads, reduces latency
sysctl -w kern.sweet_sched=29 2>/dev/null || true

# AMP scheduler: prefer A73 for UI
sysctl -w kern.sched_amp_prefer_perf=1 2>/dev/null || true

# Reduce context switch overhead
sysctl -w kern.sched_context_switch_rate=0 2>/dev/null || true

# Boost UI thread priority
sysctl -w kern.sched_ui_priority_boost=10 2>/dev/null || true

echo "Sched: sweet_sched=$(sysctl -n kern.sweet_sched 2>/dev/null) amp_prefer=$(sysctl -n kern.sched_amp_prefer_perf 2>/dev/null)"
SCHED_EOF

chmod 755 /redwood/boot.d/85-scheduler-tuning.sh

# ─────────────────────────────────────────────────────────────────
# 10. GPU FENCE ADAPTIVE SYNC (eagl.c integration)
# ─────────────────────────────────────────────────────────────────
echo "Configuring GPU fence adaptive sync..."

cat > /redwood/boot.d/85-gpu-fence-adaptive.sh <<'FENCE_EOF'
#!/bin/bash
# GPU Fence adaptive sync (complements eagl.c frame_end logic)

# Fence timeout (2ms max wait before giving up)
sysctl -w kern.sweet_gpu_fence_timeout_ms=2000 2>/dev/null || true

# Fence poll interval (50us when polling)
sysctl -w kern.sweet_gpu_fence_poll_us=50 2>/dev/null || true

# Async flush enable
sysctl -w kern.sweet_gpu_async_flush=1 2>/dev/null || true

# Skip glClientWaitSync when GPU wait <500us (eagl.c logic)
sysctl -w kern.sweet_gpu_skip_wait_threshold_us=500 2>/dev/null || true

echo "GPU Fence: timeout=$(sysctl -n kern.sweet_gpu_fence_timeout_ms 2>/dev/null) poll=$(sysctl -n kern.sweet_gpu_fence_poll_us 2>/dev/null) async=$(sysctl -n kern.sweet_gpu_async_flush 2>/dev/null)"
FENCE_EOF

chmod 755 /redwood/boot.d/85-gpu-fence-adaptive.sh

# ─────────────────────────────────────────────────────────────────
# 11. VERIFICATION
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="

echo "CPU affinity script: $( [ -f /redwood/bin/set-cpu-affinity.sh ] && echo '✓' || echo '✗' )"
echo "CPU affinity launchd: $( [ -f /redwood/launchd/com.sapphire.cpu-affinity.plist ] && echo '✓' || echo '✗' )"
echo "Kernel patch 0345: $( [ -f /redwood/patches/0345-sapphire-cpu-affinity.patch ] && echo '✓' || echo '✗' )"
echo "Kernel patch 0344: $( [ -f /redwood/patches/0344-sapphire-vsync-interrupt.patch ] && echo '✓' || echo '✗' )"
echo "Mesa glenv: $( [ -f /redwood/glenv ] && echo '✓' || echo '✗' )"
echo "CA culling boot.d: $( [ -f /redwood/boot.d/85-ca-aggressive-culling.sh ] && echo '✓' || echo '✗' )"
echo "Touch opt boot.d: $( [ -f /redwood/boot.d/85-touch-optimization.sh ] && echo '✓' || echo '✗' )"
echo "VM compressor boot.d: $( [ -f /redwood/boot.d/85-vm-compressor.sh ] && echo '✓' || echo '✗' )"
echo "DisplayLink boot.d: $( [ -f /redwood/boot.d/85-displaylink-120hz.sh ] && echo '✓' || echo '✗' )"
echo "Scheduler boot.d: $( [ -f /redwood/boot.d/85-scheduler-tuning.sh ] && echo '✓' || echo '✗' )"
echo "GPU fence boot.d: $( [ -f /redwood/boot.d/85-gpu-fence-adaptive.sh ] && echo '✓' || echo '✗' )"

echo ""
echo "=== [85] Phase 3 Ultra Fluidity complete ==="
echo "Next: 86-full-hardware-parity.sh for sensors, haptics, battery, safe area, Touch ID"
true