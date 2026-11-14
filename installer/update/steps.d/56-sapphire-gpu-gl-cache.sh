# Enable Mesa glthread and async flush in backboardd (libredwood-gl.dylib)
# and ensure HakiosMetal/SapphireGPU persists compiled shaders across boots.
# 0338: kernel-level shader cache at /var/db/sapphire_shader_cache
mkdir -p /redwood
touch /redwood/glthread /redwood/glasync
mkdir -p /private/var/db/hakios-metal-cache
chown mobile:mobile /private/var/db/hakios-metal-cache
chmod 1777 /private/var/db/hakios-metal-cache

# 0338: Persistent kernel shader cache (survives reboot)
mkdir -p /var/db
touch /var/db/sapphire_shader_cache
chown mobile:mobile /var/db/sapphire_shader_cache
chmod 666 /var/db/sapphire_shader_cache

# 0338: Ensure cache dir exists for Mesa shader cache too
mkdir -p /private/var/cache/mesa_shader_cache
chown mobile:mobile /private/var/cache/mesa_shader_cache
chmod 1777 /private/var/cache/mesa_shader_cache