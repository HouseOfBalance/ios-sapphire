# 0.4.0: Radical Fluidity - 120 Hz locked, instant touch boost, VSYNC-aligned pacing,
# dynamic render scale, async GPU pipeline, blur reduction, GMEM tiling
mkdir -p /var/jb/var /redwood/boot.d
printf '120\n' > /var/jb/var/sapphire-dl-fps
chmod 644 /var/jb/var/sapphire-dl-fps
rm -f /var/jb/var/sapphire-dl-off

# Core fluidity sysctls
sysctl -w kern.sweet_sched=13 2>/dev/null || true          # 0x0D: UT/BG prefer P, DF prefer P, no P->E migrate, idle P steals E
sysctl -w kern.sweet_fb_rscale=750 2>/dev/null || true      # static fallback (75%)
sysctl -w kern.sweet_fb_hz=240 2>/dev/null || true          # 240 Hz vsync for CA
sysctl -w kern.sweet_metal=2 2>/dev/null || true            # Metal driver mode
sysctl -w kern.sweet_glload=1 2>/dev/null || true           # GL async load

# 0333: Adaptive GPU fence polling (aggressive <200us, moderate <2ms, yield >2ms)
sysctl -w kern.sapphire_gpu_fence_hist=0 2>/dev/null || true

# 0334: Async GPU pipeline (triple buffering, max 3 in-flight)
sysctl -w kern.sweet_fb_pipeline=1 2>/dev/null || true
sysctl -w kern.sweet_fb_max_inflight=3 2>/dev/null || true

# 0335: Scheduler priority inheritance + UI thread tagging
sysctl -w kern.sweet_sched_prio_inherit=1 2>/dev/null || true

# 0336: Touch predictive polling (100ms after lift) + debounce (200us)
sysctl -w kern.sweet_touch_predictive_ms=100 2>/dev/null || true
sysctl -w kern.sweet_touch_debounce_us=200 2>/dev/null || true

# 0337: Dynamic render scaling (target 70% GPU util, 50-100% range)
sysctl -w kern.sweet_fb_dynamic_rscale=1 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_target=700 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_min=500 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_max=1000 2>/dev/null || true

# 0338: GPU command buffer batching + persistent shader cache
sysctl -w kern.sapphire_gpu_batch=0 2>/dev/null || true

# 0339: Instant touch boost - zero-latency P-core ramp
sysctl -w kern.sweet_touch_boost_enabled=1 2>/dev/null || true
sysctl -w kern.sweet_touch_boost_hold_ms=150 2>/dev/null || true

# 0340: CoreAnimation render optimizations
sysctl -w kern.sapphire_ca_disable_blur=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_halfres_backdrop=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_force_dirty_rects=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_shadow_quality=1 2>/dev/null || true

# 0341: Mesa/freedreno optimizations
sysctl -w kern.sapphire_mesa_gmem=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_glthread=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_pool=1 2>/dev/null || true

# 0342: DisplayLink VSYNC-aligned frame pacing (read-only stats)
sysctl -w kern.sapphire_dl_pacing=0 2>/dev/null || true

cat > /redwood/boot.d/55-fluidity-sysctl.sh <<'EOF'
#!/bin/bash
# Apply radical fluidity 120 Hz sysctls at boot (idempotent).
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
sysctl -w kern.sweet_sched=13 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale=750 2>/dev/null || true
sysctl -w kern.sweet_fb_hz=240 2>/dev/null || true
sysctl -w kern.sweet_metal=2 2>/dev/null || true
sysctl -w kern.sweet_glload=1 2>/dev/null || true
sysctl -w kern.sweet_fb_pipeline=1 2>/dev/null || true
sysctl -w kern.sweet_fb_max_inflight=3 2>/dev/null || true
sysctl -w kern.sweet_sched_prio_inherit=1 2>/dev/null || true
sysctl -w kern.sweet_touch_predictive_ms=100 2>/dev/null || true
sysctl -w kern.sweet_touch_debounce_us=200 2>/dev/null || true
sysctl -w kern.sweet_fb_dynamic_rscale=1 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_target=700 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_min=500 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale_max=1000 2>/dev/null || true
sysctl -w kern.sweet_touch_boost_enabled=1 2>/dev/null || true
sysctl -w kern.sweet_touch_boost_hold_ms=150 2>/dev/null || true
sysctl -w kern.sapphire_ca_disable_blur=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_halfres_backdrop=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_force_dirty_rects=1 2>/dev/null || true
sysctl -w kern.sapphire_ca_shadow_quality=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_gmem=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_glthread=1 2>/dev/null || true
sysctl -w kern.sapphire_mesa_pool=1 2>/dev/null || true
EOF
chmod 755 /redwood/boot.d/55-fluidity-sysctl.sh
true