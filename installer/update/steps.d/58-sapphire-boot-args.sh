# 0339-0342: Boot arguments for all performance optimizations (Phase 2)
# Append to existing boot args in /redwood/boot-args.txt or equivalent
BOOT_ARGS_FILE="/redwood/boot-args.txt"
TOUCH_BOOT_ARGS="/redwood/boot-args.d/99-performance.conf"

mkdir -p /redwood/boot-args.d

cat > "$TOUCH_BOOT_ARGS" <<'EOF'
# Sapphire 0339-0342 Phase 2 Performance Boot Arguments

# GPU Pipeline (0333, 0338)
gpu_batch_us=200
gpu_batch_max=64
gpu_shader_cache=1

# Display Pipeline (0334, 0337)
sweet_fb_pipeline=1
sweet_fb_max_inflight=3
sweet_fb_dyn_rscale=1
sweet_fb_rscale_target=700
sweet_fb_rscale_min=500
sweet_fb_rscale_max=1000

# Scheduler (0335, 0339)
sweet_sched=13
sweet_sched_prio_inherit=1
sweet_touch_boost_enabled=1
sweet_touch_boost_hold_ms=150

# Touch (0336)
sweet_touch_predictive_ms=100
sweet_touch_debounce_us=200

# CoreAnimation Render (0340)
sapphire_ca_disable_blur=1
sapphire_ca_halfres_backdrop=1
sapphire_ca_force_dirty_rects=1
sapphire_ca_shadow_quality=1

# Mesa/freedreno (0341)
sapphire_mesa_gmem=1
sapphire_mesa_glthread=1
sapphire_mesa_pool=1

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
    # Check if our args already present
    if ! grep -q "gpu_batch_us" "$BOOT_ARGS_FILE"; then
        cat "$TOUCH_BOOT_ARGS" | grep -v '^#' | tr '\n' ' ' >> "$BOOT_ARGS_FILE"
        echo "" >> "$BOOT_ARGS_FILE"
    fi
fi

true