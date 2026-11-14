# 0.2.2: Remove experimental metal_gmem / metal_defer flags so HakiosMetal uses its stable direct path, and restart backboardd cleanly if needed.
rm -f /var/tmp/metal.args /redwood/boot.d/58-hakios-metal-args.sh
killall -9 backboardd 2>/dev/null || true
true
