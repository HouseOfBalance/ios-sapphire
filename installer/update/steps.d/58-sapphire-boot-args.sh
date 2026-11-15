# 0339-0343: Boot arguments for all performance optimizations (Phase 2)
# Append to existing boot args in /redwood/boot-args.txt or equivalent
BOOT_ARGS_FILE="/redwood/boot-args.txt"
TOUCH_BOOT_ARGS="/redwood/boot-args.d/99-performance.conf"

mkdir -p /redwood/boot-args.d

cat > "$TOUCH_BOOT_ARGS" <<'EOF'
# Sapphire 0339-0343 Phase 2 Performance Boot Arguments

# GPU Pipeline (0333, 0338, 0341)
gpu_batch_us=200
gpu_batch_max=64
gpu_shader_cache=1

# Display Pipeline (0334, 0337, 0343)
sweet_fb_pipeline=1
sweet_fb_max_inflight=3
sweet_fb_dyn_rscale=1
sweet_fb_rscale_target=700
sweet_fb_rscale_min=500
sweet_fb_rscale_max=1000
sweet_fb_event_driven=1

# Scheduler (0335, 0339) - sweet_sched=29 enables priority inheritance (bit 4 = 0x10)
sweet_sched=29
sweet_sched_prio_inherit=1
sweet_touch_boost_enabled=1
sweet_touch_boost_hold_ms=300

# Touch (0336)
sweet_touch_predictive_ms=100
sweet_touch_debounce_us=200

# CoreAnimation Render (0340) - aggressive blur elimination
sapphire_ca_disable_blur=1
sapphire_ca_halfres_backdrop=1
sapphire_ca_force_dirty_rects=1
sapphire_ca_shadow_quality=0
sapphire_ca_max_backdrop_layers=2
sapphire_ca_color_opaque=1

# Mesa/freedreno (0341) - GMEM verification, dynamic buffer pool, LRU shader cache
sapphire_mesa_gmem=1
sapphire_mesa_glthread=1
sapphire_mesa_pool=1
mesa_gmem=1
mesa_buffer_pool_max_mb=512
mesa_shader_cache_max_mb=256

# eagl.c vblur control (disable expensive Gaussian blur on Adreno 610)
# vblur=0: disable blur entirely (CRITICAL for Control Center freeze on Adreno 610)
# vblur=2: mask-based blur (lighter, but still runs shader - NOT enough for CC freeze)
# glwait=1: CRITICAL - ensures glFinish() at frame_end, fixes Adreno 610 GMEM tiling corruption
vblur=0
glwait=1
glprecision=0

# Brightness control - use native eagl.c bridge (backboardd -> AppleCLCD)
# sweetbl=0: allows eagl.c to hook BKDisplayBrightnessController and keep CC slider unlocked
sweetbl=0

# App Launch CPU Boost Extension (0339+)
sweet_launch_boost_enabled=1
sweet_launch_boost_hold_ms=2000

# VM Compressor tuning for 120Hz animation memory pressure
vm.compressor_mode=2
vm.compressor_throughput=2000
vm.page_free_target=2000

# Debug/Profiling (disable in production)
# gpu_fence_hist=1
# sweet_fb_pipeline_debug=1
# sweet_touch_stats=1
# sapphire_ca_render=1
# sapphire_mesa=1
# sapphire_dl_pacing=1
EOF

# Also append to main boot args if file exists
if [ -f "$BOOT_ARGS_FILE" ]; then
    if ! grep -q "gpu_batch_us" "$BOOT_ARGS_FILE"; then
        cat "$TOUCH_BOOT_ARGS" | grep -v '^#' | tr '\n' ' ' >> "$BOOT_ARGS_FILE"
        echo "" >> "$BOOT_ARGS_FILE"
    fi
    # Ensure vblur=0 is explicitly present (disable Gaussian blur entirely)
    if ! grep -q "vblur=" "$BOOT_ARGS_FILE"; then
        echo -n " vblur=0" >> "$BOOT_ARGS_FILE"
    fi
fi

true