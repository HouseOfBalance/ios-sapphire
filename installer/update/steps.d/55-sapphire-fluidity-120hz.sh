# 0.1.9: 120 Hz display-link fluidity, AMP cluster scheduler (sweet_sched=15), and 85% GPU render scale (sweet_fb_rscale=850).
mkdir -p /var/jb/var /redwood/boot.d
printf '120\n' > /var/jb/var/sapphire-dl-fps
chmod 644 /var/jb/var/sapphire-dl-fps
rm -f /var/jb/var/sapphire-dl-off

cat > /redwood/boot.d/55-fluidity-sysctl.sh <<'EOF'
#!/bin/bash
# Apply fluidity 120 Hz / scheduler / render-scale sysctls at boot (idempotent).
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
sysctl -w kern.sweet_sched=15 2>/dev/null || true
sysctl -w kern.sweet_fb_rscale=850 2>/dev/null || true
sysctl -w kern.sweet_metal=2 2>/dev/null || true
sysctl -w kern.sweet_glload=1 2>/dev/null || true
EOF
chmod 755 /redwood/boot.d/55-fluidity-sysctl.sh
true
