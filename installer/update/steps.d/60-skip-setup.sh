#!/bin/bash
# 60-skip-setup.sh: Bypass Setup.app (PurpleBuddy) and DataMigration loops
# This allows iOS to boot directly to SpringBoard home screen / lock screen.

PREF_DIR="/private/var/mobile/Library/Preferences"
ROOT_PREF_DIR="/private/var/root/Library/Preferences"
mkdir -p "$PREF_DIR" "$ROOT_PREF_DIR"

# 1. PurpleBuddy (Setup.app) - Mark Setup as fully completed
cat > "$PREF_DIR/com.apple.purplebuddy.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SetupDone</key>
	<true/>
	<key>SetupFinishedAllSteps</key>
	<true/>
	<key>SetupVersion</key>
	<integer>11</integer>
	<key>daemonizeNeedsToRun</key>
	<false/>
</dict>
</plist>
EOF

cat > "$PREF_DIR/com.apple.purplebuddy.notbackedup.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>MiniBuddyNavComplete</key>
	<true/>
	<key>MiniBuddyVoiceOverDone</key>
	<true/>
	<key>MiniBuddyLookAtMeDone</key>
	<true/>
	<key>ShouldRunDiagnosticsMiniBuddy</key>
	<false/>
	<key>ShouldRunHSA2MiniBuddy</key>
	<false/>
	<key>ShouldRunKeychainSyncMiniBuddy</key>
	<false/>
	<key>ShouldRunMesaMiniBuddy</key>
	<false/>
	<key>ShouldRunPaymentMiniBuddy</key>
	<false/>
	<key>ShouldRunStandardMiniBuddy</key>
	<false/>
	<key>SilentICDPUpgrade</key>
	<false/>
</dict>
</plist>
EOF

# 2. DataMigration - Mark migration as already run for 16.7.16 / 20H392
cat > "$PREF_DIR/com.apple.migration.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DMUserDataDisposition</key>
	<dict>
		<key>SyntheticDidUpgrade</key>
		<false/>
		<key>buildVersion</key>
		<string>20H392</string>
	</dict>
	<key>LastSystemVersion</key>
	<string>20H392</string>
</dict>
</plist>
EOF

cat > "$PREF_DIR/com.apple.datamigrator.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DataMigrationAlreadyRan</key>
	<true/>
	<key>LastBuildVersion</key>
	<string>20H392</string>
	<key>LastSystemVersion</key>
	<string>16.7.16</string>
</dict>
</plist>
EOF

# 3. SpringBoard & Cloud Configuration & Accessibility
# Clean up any bad plists from prior attempts
rm -f "$PREF_DIR/com.apple.CoreAnimation.plist" "$PREF_DIR/com.apple.MaterialKit.plist"
rm -f "$ROOT_PREF_DIR/com.apple.CoreAnimation.plist" "$ROOT_PREF_DIR/com.apple.MaterialKit.plist"

cat > "$PREF_DIR/com.apple.springboard.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BKNoWatchdogs</key>
	<true/>
	<key>FBLaunchWatchdogExceptions</key>
	<dict>
		<key>com.apple.purplebuddy</key>
		<real>100.0</real>
	</dict>
	<key>MCForceShowCloudConfigurationUI</key>
	<false/>
	<key>SBDisableParallax</key>
	<true/>
	<key>SBReduceMotion</key>
	<true/>
</dict>
</plist>
EOF

cat > "$PREF_DIR/com.apple.Accessibility.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnhanceBackgroundContrast</key>
	<true/>
	<key>ReduceMotion</key>
	<true/>
	<key>ReduceTransparency</key>
	<true/>
</dict>
</plist>
EOF

cat > "$PREF_DIR/com.apple.managedconfiguration.notbackedup.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LockdownActivationIndicatesCloudConfigurationAvailable</key>
	<false/>
</dict>
</plist>
EOF

# 4. Activation state (data_ark.plist)
for meta in /private/var/containers/Data/System/*/.com.apple.mobile_container_manager.metadata.plist; do
    if [ -f "$meta" ] && grep -q "com.apple.mobileactivationd" "$meta" 2>/dev/null; then
        D="$(dirname "$meta")/Library/internal"
        mkdir -p "$D"
        cat > "$D/data_ark.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>-ActivationState</key>
	<string>Activated</string>
	<key>-BrickState</key>
	<false/>
	<key>-BuildVersion</key>
	<string>20H392</string>
	<key>-ProductVersion</key>
	<string>16.7.16</string>
	<key>-DataMigrationCompleted</key>
	<true/>
	<key>-PreSydroDataMigrationCompleted</key>
	<true/>
</dict>
</plist>
EOF
        chown -R 501:501 "$D"
        chmod 600 "$D/data_ark.plist"
    fi
done

# Fallback data_ark in /private/var/mobile/Library/internal
mkdir -p /private/var/mobile/Library/internal
cp -p "$PREF_DIR/com.apple.purplebuddy.plist" /private/var/mobile/Library/internal/ 2>/dev/null || true

# Copy configs to root preferences as well
cp -p "$PREF_DIR"/com.apple.*.plist "$ROOT_PREF_DIR/" 2>/dev/null || true
chown -R 0:0 "$ROOT_PREF_DIR"
chmod 600 "$ROOT_PREF_DIR"/*.plist 2>/dev/null || true

# Set correct mobile ownership and permissions
chown -R 501:501 "$PREF_DIR"
chmod 600 "$PREF_DIR"/*.plist

echo "Setup bypass preferences configured successfully."

# Terminate Setup, DataMigration, cfprefsd, and respring SpringBoard cleanly
killall -9 Setup com.apple.datamigrator com.apple.migrationpluginwrapper cfprefsd 2>/dev/null || true
sleep 1
killall -9 SpringBoard 2>/dev/null || true

true
