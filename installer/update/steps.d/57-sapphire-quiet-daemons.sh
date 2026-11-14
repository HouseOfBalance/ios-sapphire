# Silence/disable background CPU-hogging and crashing daemons
P=/redwood/bin/plistop
C=/System/Library/xpc/launchd.plist
B=/var/root/launchd.plist.pre-quiet
JOBS="com.apple.parsecd com.apple.cdpd com.apple.searchpartyd com.apple.biomesyncd com.apple.duetexpertd com.apple.parsec-fbf"

if [ -f "$C" ] && [ -x "$P" ]; then
	if [ -f "$B" ] || cp -p "$C" "$B"; then
		set --
		for j in $JOBS; do
			set -- "$@" del-each LaunchDaemons Label "$j"
		done
		"$P" "$C" "$@" || true
	fi
fi

L=launchctl
command -v "$L" >/dev/null 2>&1 || L=/var/jb/usr/bin/launchctl
for j in $JOBS; do
	"$L" disable "system/$j" 2>/dev/null || true
	"$L" bootout "system/$j" 2>/dev/null || true
done

true
