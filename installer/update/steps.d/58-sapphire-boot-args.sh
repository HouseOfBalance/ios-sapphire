# 0339: Boot arguments for all performance optimizations
# Append to existing boot args in /redwood/boot-args.txt or equivalent
BOOT_ARGS_FILE="/redwood/boot-args.txt"
TOUCH_BOOT_ARGS="/redwood/boot-args.d/99-performance.conf"

mkdir -p /redwood/boot-args.d

cat > "$TOUCH_BOOT_ARGS" <<'EOF'
# Sapphire 0339 Performance Boot Arguments
# GPU Pipeline
gpu_batch_us=200
gpu_batch_max=64
gpu_shader_cache=1

# Display Pipeline
sweet_fb_pipeline=1
sweet_fb_max_inflight=3
sweet_fb_dyn_rscale=1
sweet_fb_rscale_target=700
sweet_fb_rscale_min=500
sweet_fb_rscale_max=1000

# Scheduler
sweet_sched=13
sweet_sched_prio_inherit=1

# Touch
sweet_touch_predictive_ms=100
sweet_touch_debounce_us=200

# Debug/Profiling (disable in production)
# gpu_fence_hist=1
# sweet_fb_pipeline_debug=1
# sweet_touch_stats=1
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