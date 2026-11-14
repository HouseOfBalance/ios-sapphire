# 0.2.0: enable HakiosMetal on-chip 128 KB GMEM tile rendering (gmem_min_draws=0) and deferred command buffer encoding.
mkdir -p /var/tmp /redwood/boot.d
printf 'metal_gmem=1 metal_defer=1\n' > /var/tmp/metal.args
chmod 644 /var/tmp/metal.args

cat > /redwood/boot.d/58-hakios-metal-args.sh <<'EOF'
#!/bin/bash
mkdir -p /var/tmp
printf 'metal_gmem=1 metal_defer=1\n' > /var/tmp/metal.args
chmod 644 /var/tmp/metal.args
EOF
chmod 755 /redwood/boot.d/58-hakios-metal-args.sh
true
