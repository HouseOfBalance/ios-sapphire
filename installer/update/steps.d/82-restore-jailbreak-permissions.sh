#!/bin/bash
# 82-restore-jailbreak-permissions.sh: Restore Procursus jailbreak environment
# Fixes Sileo crash (lost entitlements) and Zebra Demo Mode (lost setuid)
# Run AFTER all other fix scripts (70-81) and master installer
# CRITICAL ORDER: chmod 4755 MUST be AFTER ldid signing (kernel drops setuid on write)

set -e

echo "=== [82] Restoring Jailbreak Permissions & Entitlements ==="

JB_ROOT="/private/var/jb"
JB_APPS="$JB_ROOT/Applications"
IOS_APPS="/Applications"

# ─────────────────────────────────────────────────────────────────
# 1. REMOVE ANY BLIND ldid -S LOOPS FROM PREVIOUS SCRIPTS
#    (Prevent re-corruption on subsequent runs)
# ─────────────────────────────────────────────────────────────────
echo "Sanitizing previous scripts to remove blind ldid -S..."
for script in /redwood/update/steps.d/*.sh /redwood/boot.d/*.sh /redwood/bin/*.sh; do
    if [ -f "$script" ]; then
        sed -i -E \
            -e '/find .*ldid -S/d' \
            -e '/ldid -S "\$bin"/d' \
            -e '/ldid -S \$bin/d' \
            -e '/xargs ldid -S/d' \
            -e '/while read bin; do.*ldid -S/d' \
            "$script" 2>/dev/null || true
    fi
done
echo "  ✓ Removed blind ldid -S patterns from scripts"

# ─────────────────────────────────────────────────────────────────
# 2. RESTORE OWNERSHIP (root:wheel = 0:0) ON ENTIRE /var/jb TREE
#    THEN RESTORE mobile (501:501) FOR USER DIRECTORIES
# ─────────────────────────────────────────────────────────────────
echo "Restoring ownership to root:wheel (0:0) on $JB_ROOT..."
chown -R 0:0 "$JB_ROOT" 2>/dev/null || true

# CRITICAL: Restore mobile ownership for user-writable directories
echo "Restoring mobile (501:501) ownership for user directories..."
chown -R 501:501 "$JB_ROOT/var/mobile" 2>/dev/null || true
chown -R 501:501 "$JB_ROOT/var/lib/apt/sileolists" 2>/dev/null || true
chown -R 501:501 "$JB_ROOT/var/cache/apt/archives" 2>/dev/null || true
chown -R 501:501 "$JB_ROOT/tmp" 2>/dev/null || true
echo "  ✓ chown complete (0:0 for system, 501:501 for user data)"

# ─────────────────────────────────────────────────────────────────
# 3. CREATE PROPER ENTITLEMENTS XML FOR ROOTLESS APPS
# ─────────────────────────────────────────────────────────────────
ENTITLEMENTS_XML="/tmp/rootless_entitlements.plist"
cat > "$ENTITLEMENTS_XML" <<'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.apple.private.skip-library-validation</key>
    <true/>
    <key>get-task-allow</key>
    <true/>
    <key>com.apple.private.persona-mgmt</key>
    <true/>
</dict>
</plist>
ENTEOF

echo "Created entitlements template: $ENTITLEMENTS_XML"

# ─────────────────────────────────────────────────────────────────
# 4. RE-SIGN SILEO & ZEBRA WITH CORRECT ENTITLEMENTS
#    THEN APPLY SETUID (4755) - ORDER IS CRITICAL!
#    Must sign BOTH /private/var/jb/Applications AND /Applications
# ─────────────────────────────────────────────────────────────────
LDID_BIN="/var/jb/usr/bin/ldid"
if [ ! -x "$LDID_BIN" ]; then
    LDID_BIN="/usr/bin/ldid"
fi
if [ ! -x "$LDID_BIN" ]; then
    echo "  ✗ ldid not found! Cannot re-sign apps."
else
    echo "Re-signing with ldid: $LDID_BIN"

    # Helper function: sign binary, then set setuid if helper
    sign_and_fix() {
        local bin="$1"
        local is_helper="$2"
        if [ -f "$bin" ]; then
            "$LDID_BIN" -S"$ENTITLEMENTS_XML" "$bin" 2>/dev/null && \
                echo "  ✓ Signed: ${bin}"
            # Setuid MUST be AFTER ldid (kernel drops S_ISUID on write)
            if [ "$is_helper" = "1" ]; then
                chmod 4755 "$bin" && echo "  ✓ Setuid 4755: ${bin}"
            fi
        else
            echo "  ⚠ Not found: $bin"
        fi
    }

    # Sileo - BOTH locations
    sign_and_fix "$JB_APPS/Sileo.app/Sileo" 0
    sign_and_fix "$JB_APPS/Sileo.app/giveMeRoot" 1
    sign_and_fix "$IOS_APPS/Sileo.app/Sileo" 0
    sign_and_fix "$IOS_APPS/Sileo.app/giveMeRoot" 1

    # Zebra - BOTH locations
    sign_and_fix "$JB_APPS/Zebra.app/Zebra" 0
    sign_and_fix "$JB_APPS/Zebra.app/giveMeRoot" 1
    sign_and_fix "$IOS_APPS/Zebra.app/Zebra" 0
    sign_and_fix "$IOS_APPS/Zebra.app/giveMeRoot" 1

    # Core system binaries - sign then setuid
    for sys_bin in \
        "$JB_ROOT/usr/bin/sudo" \
        "$JB_ROOT/bin/su" \
        "$JB_ROOT/usr/bin/login" \
        "$JB_ROOT/usr/bin/passwd" \
        "$JB_ROOT/usr/bin/apt" \
        "$JB_ROOT/usr/bin/dpkg" \
        "$JB_ROOT/usr/bin/apt-get" \
        "$JB_ROOT/usr/bin/apt-cache"; do
        if [ -f "$sys_bin" ]; then
            "$LDID_BIN" -S"$ENTITLEMENTS_XML" "$sys_bin" 2>/dev/null && \
                echo "  ✓ Signed: ${sys_bin##*/}"
            # These MUST be setuid
            chmod 4755 "$sys_bin" && echo "  ✓ Setuid 4755: ${sys_bin##*/}"
        fi
    done
fi

# Cleanup temp entitlements file
rm -f "$ENTITLEMENTS_XML"

# ─────────────────────────────────────────────────────────────────
# 5. ENSURE APT SANDBOX CONFIG (Prevents _apt user drop failure)
# ─────────────────────────────────────────────────────────────────
APT_CONF_DIR="$JB_ROOT/etc/apt/apt.conf.d"
mkdir -p "$APT_CONF_DIR"
APT_SANDBOX_CONF="$APT_CONF_DIR/20sapphire-sandbox.conf"

cat > "$APT_SANDBOX_CONF" <<'APTEOF'
APT::Sandbox::User "root";
Dir::Bin::methods "/var/jb/usr/libexec/apt/methods";
Dir::Bin::solvers "/var/jb/usr/libexec/apt/solvers";
APT::Sandbox::Seccomp "false";
DPkg::Pre-Install-Pkgs {"/var/jb/usr/libexec/dpkg-pre-install";};
APTEOF

chown 0:0 "$APT_SANDBOX_CONF"
chmod 644 "$APT_SANDBOX_CONF"
echo "  ✓ Created $APT_SANDBOX_CONF"

# ─────────────────────────────────────────────────────────────────
# 5b. FIX SILEO / APT HTTPS METHOD DRIVER & LOG PERMISSIONS
# ─────────────────────────────────────────────────────────────────
echo "Fixing Sileo / APT HTTPS transport & log permissions..."

mkdir -p "$JB_ROOT/usr/lib/apt/methods" 2>/dev/null || true
mkdir -p "$JB_ROOT/usr/libexec/apt/methods" 2>/dev/null || true
mkdir -p "$JB_ROOT/var/log" 2>/dev/null || true

# 5b.1 In Procursus APT, https method is a symlink to http (uses libcurl + libgnutls from http method)
# Check BOTH possible locations for http method
for methods_dir in "$JB_ROOT/usr/lib/apt/methods" "$JB_ROOT/usr/libexec/apt/methods"; do
    if [ -f "$methods_dir/http" ]; then
        ln -sf http "$methods_dir/https"
        chmod 755 "$methods_dir/http" "$methods_dir/https" 2>/dev/null || true
        echo "  ✓ Created symlink: $methods_dir/https -> http"
    fi
done

# Fallback check for rootfs /usr/lib/apt/methods
if [ -d "/usr/lib/apt/methods" ] && [ -f "/usr/lib/apt/methods/http" ]; then
    ln -sf http "/usr/lib/apt/methods/https" 2>/dev/null || true
fi

# 5b.2 Fix log directory permissions for user mobile (UID 501)
chmod 777 "$JB_ROOT/var/log" 2>/dev/null || true

# 5b.3 Fix aptwrap.log - ensure it's writable by mobile (UID 501)
touch "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true
chmod 666 "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true
chown 501:501 "$JB_ROOT/var/log/aptwrap.log" 2>/dev/null || true

# 5b.4 Fix /var/jb/usr/bin/apt-get wrapper script if it exists
# The wrapper may write to /var/jb/var/log/aptwrap.log which mobile can't write to
# Fix by redirecting to /tmp/aptwrap.log (world-writable)
# DON'T use 'file' command (not available on iOS) - just check if it's a script by reading first line
if [ -f "$JB_ROOT/usr/bin/apt-get" ]; then
    first_line=$(head -c 2 "$JB_ROOT/usr/bin/apt-get" 2>/dev/null)
    if [ "$first_line" = "#!" ]; then
        sed -i 's|/var/jb/var/log/aptwrap.log|/tmp/aptwrap.log|g' "$JB_ROOT/usr/bin/apt-get" 2>/dev/null || true
        echo "  ✓ Fixed apt-get wrapper log path to /tmp/aptwrap.log"
    fi
fi

# 5b.5 Ensure CaInfo is set for HTTPS (libgnutls needs this)
APT_CA_CONF="$APT_CONF_DIR/10sapphire.conf"
if [ ! -f "$APT_CA_CONF" ]; then
    cat > "$APT_CA_CONF" <<'CAEOF'
Acquire::https::CaInfo "/var/jb/etc/ssl/certs/cacert.pem";
CAEOF
    chown 0:0 "$APT_CA_CONF"
    chmod 644 "$APT_CA_CONF"
    echo "  ✓ Created APT CaInfo config: $APT_CA_CONF"
fi

echo "  ✓ Sileo APT HTTPS transport, log permissions, and sandbox config restored"

# ─────────────────────────────────────────────────────────────────
# 6. FIX SYMLINKS (/var/jb -> /private/var/jb)
# ─────────────────────────────────────────────────────────────────
echo "Fixing symlinks..."
if [ -L /var/jb ]; then
    CURRENT_TARGET=$(readlink /var/jb)
    if [ "$CURRENT_TARGET" != "private/var/jb" ]; then
        rm -f /var/jb
        ln -s private/var/jb /var/jb
        echo "  ✓ Fixed /var/jb symlink"
    else
        echo "  ✓ /var/jb symlink already correct"
    fi
else
    ln -s private/var/jb /var/jb
    echo "  ✓ Created /var/jb symlink"
fi

# Ensure /var is a symlink to private/var (iOS standard)
if [ -L /var ]; then
    VAR_TARGET=$(readlink /var)
    if [ "$VAR_TARGET" != "private/var" ]; then
        rm -f /var
        ln -s private/var /var
        echo "  ✓ Fixed /var symlink"
    fi
else
    echo "  ⚠ /var is not a symlink (may be directory on this build)"
fi

# ─────────────────────────────────────────────────────────────────
# 7. VERIFY PERMISSIONS ON KEY DIRECTORIES
# ─────────────────────────────────────────────────────────────────
echo "Verifying key directory permissions..."

# /var/jb/var should be symlink to /var/jb/private/var
[ -L "$JB_ROOT/var" ] || ln -sf private/var "$JB_ROOT/var"

# /var/jb/tmp permissions (world-writable + sticky) - mobile owns this
mkdir -p "$JB_ROOT/tmp"
chmod 1777 "$JB_ROOT/tmp"
chown 501:501 "$JB_ROOT/tmp"

# /var/jb/run for daemons
mkdir -p "$JB_ROOT/run"
chmod 755 "$JB_ROOT/run"

# /var/jb/var/cache/apt/archives for package downloads
mkdir -p "$JB_ROOT/var/cache/apt/archives"
chmod 755 "$JB_ROOT/var/cache/apt/archives"
chown 501:501 "$JB_ROOT/var/cache/apt/archives"

# /var/jb/var/lib/dpkg for dpkg database
mkdir -p "$JB_ROOT/var/lib/dpkg"
chmod 755 "$JB_ROOT/var/lib/dpkg"

echo "  ✓ Directory permissions verified"

# ─────────────────────────────────────────────────────────────────
# 8. REBUILD UI CACHE (SpringBoard recognizes apps again)
# ─────────────────────────────────────────────────────────────────
echo "Rebuilding UI cache..."
UICACHE_BIN="/var/jb/usr/bin/uicache"
if [ ! -x "$UICACHE_BIN" ]; then
    UICACHE_BIN="/usr/bin/uicache"
fi

if [ -x "$UICACHE_BIN" ]; then
    # Run uicache for Sileo and Zebra specifically
    "$UICACHE_BIN" -p "$JB_APPS/Sileo.app" -p "$JB_APPS/Zebra.app" 2>/dev/null || \
        "$UICACHE_BIN" --all 2>/dev/null || \
        "$UICACHE_BIN" 2>/dev/null || true
    echo "  ✓ uicache executed"
else
    echo "  ⚠ uicache not found, skipping (apps will refresh on respring)"
fi

# ─────────────────────────────────────────────────────────────────
# 9. REMOVE MALICIOUS BOOT.D SCRIPTS THAT TARGET /var/jb
# ─────────────────────────────────────────────────────────────────
echo "Removing malicious boot scripts that target /var/jb..."
rm -f /redwood/boot.d/73-sign-var-binaries.sh 2>/dev/null
rm -f /redwood/bin/sign-var-binaries.sh 2>/dev/null
# These are recreated by 73-trollstore-amfi-fix.sh WITHOUT /var/jb targeting

# ─────────────────────────────────────────────────────────────────
# 10. FINAL VERIFICATION
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="

# Check Sileo (both locations)
for loc in "$JB_APPS" "$IOS_APPS"; do
    if [ -f "$loc/Sileo.app/Sileo" ]; then
        ENT=$("$LDID_BIN" -e "$loc/Sileo.app/Sileo" 2>/dev/null | grep -E 'platform-application|no-sandbox|skip-library-validation|get-task-allow' | wc -l)
        PERM=$(stat -f "%Mp%Lp" "$loc/Sileo.app/Sileo" 2>/dev/null || stat -c "%a" "$loc/Sileo.app/Sileo" 2>/dev/null)
        echo "  Sileo ($loc): perms=$PERM entitlements=$ENT/4"
    fi
    if [ -f "$loc/Sileo.app/giveMeRoot" ]; then
        PERM=$(stat -f "%Mp%Lp" "$loc/Sileo.app/giveMeRoot" 2>/dev/null || stat -c "%a" "$loc/Sileo.app/giveMeRoot" 2>/dev/null)
        echo "  Sileo giveMeRoot ($loc): perms=$PERM (expect 4755)"
    fi
done

# Check Zebra (both locations)
for loc in "$JB_APPS" "$IOS_APPS"; do
    if [ -f "$loc/Zebra.app/Zebra" ]; then
        ENT=$("$LDID_BIN" -e "$loc/Zebra.app/Zebra" 2>/dev/null | grep -E 'platform-application|no-sandbox|skip-library-validation|get-task-allow' | wc -l)
        PERM=$(stat -f "%Mp%Lp" "$loc/Zebra.app/Zebra" 2>/dev/null || stat -c "%a" "$loc/Zebra.app/Zebra" 2>/dev/null)
        echo "  Zebra ($loc): perms=$PERM entitlements=$ENT/4"
    fi
    if [ -f "$loc/Zebra.app/giveMeRoot" ]; then
        PERM=$(stat -f "%Mp%Lp" "$loc/Zebra.app/giveMeRoot" 2>/dev/null || stat -c "%a" "$loc/Zebra.app/giveMeRoot" 2>/dev/null)
        echo "  Zebra giveMeRoot ($loc): perms=$PERM (expect 4755)"
    fi
done

# Check APT config
if [ -f "$APT_SANDBOX_CONF" ]; then
    echo "  APT sandbox config: ✓"
else
    echo "  APT sandbox config: MISSING"
fi

# Check symlinks
echo "  /var/jb -> $(readlink /var/jb 2>/dev/null || echo 'BROKEN')"
echo "  /var -> $(readlink /var 2>/dev/null || echo 'BROKEN')"

# Check mobile ownership
echo "  /var/jb/var/mobile owner: $(stat -f "%Su" "$JB_ROOT/var/mobile" 2>/dev/null || stat -c "%U" "$JB_ROOT/var/mobile" 2>/dev/null)"

echo ""
echo "=== [82] Jailbreak permissions restored ==="
echo "Next steps:"
echo "  1. Respring or reboot to iOS"
echo "  2. Open Sileo - should launch without crash"
echo "  3. Open Zebra - should show full package manager (not Demo Mode)"
true