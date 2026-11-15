#!/bin/bash
# 63-mesa-cache-perms.sh: Ensure Mesa shader cache is accessible by all GPU processes
# App processes need read/write access to the cache directory

set -e

echo "=== [63] Configuring Mesa shader cache permissions ==="

# Mesa shader cache directory (created by 56-sapphire-gpu-gl-cache.sh)
CACHE_DIR="/private/var/cache/mesa_shader_cache"

# Ensure directory exists with proper permissions
mkdir -p "$CACHE_DIR"
chown -R 501:501 "$CACHE_DIR"
chmod 1777 "$CACHE_DIR"  # sticky bit: users can only delete their own files

# Also ensure the kernel shader cache is accessible
mkdir -p /var/db
chown 501:501 /var/db/sapphire_shader_cache 2>/dev/null || true
chmod 666 /var/db/sapphire_shader_cache 2>/dev/null || true

# Mesa buffer pool directory
mkdir -p /private/var/cache/mesa_buffer_pool
chown -R 501:501 /private/var/cache/mesa_buffer_pool
chmod 1777 /private/var/cache/mesa_buffer_pool

# HakiosMetal cache
mkdir -p /private/var/db/hakios-metal-cache
chown -R 501:501 /private/var/db/hakios-metal-cache
chmod 1777 /private/var/db/hakios-metal-cache

# Ensure /redwood/glenv has the cache env vars (read by eagl.c at process launch)
if [ -f /redwood/glenv ]; then
    # Verify cache env vars are present
    if ! grep -q "MESA_SHADER_CACHE_DIR" /redwood/glenv; then
        cat >> /redwood/glenv <<'EOF'

# Mesa shader cache (persistent across reboots)
MESA_SHADER_CACHE_DIR=/private/var/cache/mesa_shader_cache
MESA_SHADER_CACHE_ENABLE=true
MESA_GLSL_CACHE_DISABLE=false
EOF
    fi
fi

# Also update boot.d script for processes not using eagl.c
if [ -f /redwood/boot.d/56-mesa-env.sh ]; then
    if ! grep -q "MESA_SHADER_CACHE_DIR" /redwood/boot.d/56-mesa-env.sh; then
        cat >> /redwood/boot.d/56-mesa-env.sh <<'EOF'

# Mesa shader cache (persistent across reboots)
export MESA_SHADER_CACHE_DIR=/private/var/cache/mesa_shader_cache
export MESA_SHADER_CACHE_ENABLE=true
export MESA_GLSL_CACHE_DISABLE=false
EOF
    fi
fi

echo "=== [63] Mesa shader cache permissions configured ==="
true