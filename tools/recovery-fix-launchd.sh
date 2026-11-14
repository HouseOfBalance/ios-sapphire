#!/bin/bash
# recovery-fix-launchd.sh - Run from Recovery mode to fix broken launchd.plist
# Usage: ./recovery-fix-launchd.sh <iosroot_mount_point>
# Example: ./recovery-fix-launchd.sh /mnt/iosroot

set -e

IOSROOT="${1:-/mnt/iosroot}"
LAUNCHD_PLIST="$IOSROOT/System/Library/xpc/launchd.plist"
LAUNCHD_BACKUP="$IOSROOT/var/root/launchd.plist.pre-quiet"
PLOP_BIN="$IOSROOT/redwood/bin/plistop"

echo "=== Sapphire Recovery: Fix launchd.plist ==="
echo "iOS root: $IOSROOT"
echo "launchd.plist: $LAUNCHD_PLIST"
echo "Backup: $LAUNCHD_BACKUP"
echo ""

# Check if iOS root is mounted
if [ ! -f "$LAUNCHD_PLIST" ]; then
    echo "ERROR: launchd.plist not found at $LAUNCHD_PLIST"
    echo "Mount iosroot partition first:"
    echo "  mount -t hfsplus /dev/block/by-name/userdata $IOSROOT"
    exit 1
fi

# Check if backup exists
if [ -f "$LAUNCHD_BACKUP" ]; then
    echo "Found backup, restoring..."
    cp -p "$LAUNCHD_BACKUP" "$LAUNCHD_PLIST"
    echo "Restored launchd.plist from backup"
else
    echo "No backup found. Rebuilding minimal launchd.plist..."

    # Create minimal launchd.plist with critical daemons
    cat > "$LAUNCHD_PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.apple.launchd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/launchd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LaunchDaemons</key>
    <dict>
        <key>com.apple.containermanagerd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.containermanagerd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/containermanagerd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.cfprefsd.xpc.daemon</key>
        <dict>
            <key>Label</key>
            <string>com.apple.cfprefsd.xpc.daemon</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/cfprefsd.xpc.daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.securityd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.securityd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/sbin/securityd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.trustd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.trustd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/trustd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.locationd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.locationd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/locationd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.geod</key>
        <dict>
            <key>Label</key>
            <string>com.apple.geod</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/geod</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.wifid</key>
        <dict>
            <key>Label</key>
            <string>com.apple.wifid</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/wifid</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.bluetoothd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.bluetoothd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/bluetoothd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.mavrouterd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.mavrouterd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/mavrouterd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.pcscd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.pcscd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/sbin/pcscd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.networking.wifid</key>
        <dict>
            <key>Label</key>
            <string>com.apple.networking.wifid</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/networking.wifid</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.networking.wifip2pd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.networking.wifip2pd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/networking.wifip2pd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.nehelper</key>
        <dict>
            <key>Label</key>
            <string>com.apple.nehelper</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/nehelper</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.networkd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.networkd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/networkd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.apsd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.apsd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/apsd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.pushd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.pushd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/pushd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.accountsd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.accountsd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/accountsd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.icloud.fmfd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.icloud.fmfd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/fmfd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.findmydeviced</key>
        <dict>
            <key>Label</key>
            <string>com.apple.findmydeviced</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/findmydeviced</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.passd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.passd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/passd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.paymentd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.paymentd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/paymentd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.commerce</key>
        <dict>
            <key>Label</key>
            <string>com.apple.commerce</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/commerce</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.mobileassetd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.mobileassetd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/mobileassetd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.appstored</key>
        <dict>
            <key>Label</key>
            <string>com.apple.appstored</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/appstored</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.itunesstored</key>
        <dict>
            <key>Label</key>
            <string>com.apple.itunesstored</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/itunesstored</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.coresymbolicationd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.coresymbolicationd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/coresymbolicationd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.coreduetd</key>
        <dict>
            <key>Label</key>
            <string>com.apple.coreduetd</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/coreduetd</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.coreduetd.osx</key>
        <dict>
            <key>Label</key>
            <string>com.apple.coreduetd.osx</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/coreduetd.osx</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.spotlight</key>
        <dict>
            <key>Label</key>
            <string>com.apple.spotlight</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/spotlight</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.metadata.mds</key>
        <dict>
            <key>Label</key>
            <string>com.apple.metadata.mds</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/mds</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        <key>com.apple.metadata.mdwrite</key>
        <dict>
            <key>Label</key>
            <string>com.apple.metadata.mdwrite</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/libexec/mdwrite</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
    </dict>
</dict>
</plist>
PLIST_EOF
    echo "Created minimal launchd.plist with critical daemons"
fi

# Verify the plist is valid
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$LAUNCHD_PLIST" && echo "launchd.plist syntax OK"
else
    echo "plutil not available, skipping syntax check"
fi

# Also fix the quiet-daemons script on the target
QUIET_DAEMONS="$IOSROOT/installer/update/steps.d/57-sapphire-quiet-daemons.sh"
if [ -f "$QUIET_DAEMONS" ]; then
    echo "Updating 57-sapphire-quiet-daemons.sh on target..."
    # The fixed version should already be in the update package
    # But we can also patch it in-place
    sed -i 's/com.apple.containermanagerd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.cfprefsd.xpc.daemon//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.securityd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.trustd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.locationd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.geod//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.wifid//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.bluetoothd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.mavrouterd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.pcscd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.networking.wifid//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.networking.wifip2pd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.nehelper//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.networkd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.apsd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.pushd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.accountsd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.icloud.fmfd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.findmydeviced//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.passd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.paymentd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.commerce//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.mobileassetd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.appstored//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.itunesstored//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.coresymbolicationd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.coreduetd//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.coreduetd.osx//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.spotlight//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.metadata.mds//g' "$QUIET_DAEMONS"
    sed -i 's/com.apple.metadata.mdwrite//g' "$QUIET_DAEMONS"
    echo "Patched 57-sapphire-quiet-daemons.sh to remove critical daemons"
fi

echo ""
echo "=== Recovery fix complete ==="
echo "Now reboot to iOS:"
echo "  reboot"
echo ""
echo "Or if using fastboot:"
echo "  fastboot reboot"