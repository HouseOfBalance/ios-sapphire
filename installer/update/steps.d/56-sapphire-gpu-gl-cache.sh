# Enable Mesa glthread and async flush in backboardd (libredwood-gl.dylib)
# and ensure HakiosMetal persists compiled shaders across boots.
mkdir -p /redwood
touch /redwood/glthread /redwood/glasync
mkdir -p /private/var/db/hakios-metal-cache
chown mobile:mobile /private/var/db/hakios-metal-cache
chmod 1777 /private/var/db/hakios-metal-cache
