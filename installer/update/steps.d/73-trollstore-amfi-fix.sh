#!/bin/bash
# 73-trollstore-amfi-fix.sh: Fix TrollStore Sideloaded Apps Crash (SWEET AMFI)
# Root cause: TrollStore apps install to /private/var/containers/Bundle/Application/
# (on /private/var, NOT rootfs). The SWEET AMFI policy in 0036-sweet-amfi-cs-signed.patch
# only grants CS_PLATFORM_BINARY to binaries on MNT_ROOTFS. Apps on /var lack Apple CDHashes
# and get killed with CS_KILLED (OS_REASON_EXEC) by dyld/AMFI.
#
# Fix approach:
# 1. Kernel patch: In sweet_amfi_vnode_check_signature, grant CS_PLATFORM_BINARY to
#    ANY binary with a valid code directory (ubc_cs_blob), not just rootfs binaries.
#    This is done by modifying the cs_blob flags directly, not via non-existent cs_flags param.
# 2. Runtime: ad-hoc sign ONLY TrollStore app binaries in /private/var/containers/
#    DO NOT touch /var/jb binaries - they are managed by 82-restore-jailbreak-permissions.sh

set -e

echo "=== [73] Fixing TrollStore App Crashes (SWEET AMFI) ==="

# 1. Create CORRECT kernel patch for sweet_amfi.c
# The mpo_vnode_check_signature hook signature is:
#   int (*mpo_vnode_check_signature)(struct vnode *vp, struct label *label,
#                                     char **fatal_failure_desc, size_t *fatal_failure_desc_len);
# There is NO cs_flags parameter. The CS flags are stored in the vnode's ubc_cs_blob.
# We must modify the code directory blob directly.

mkdir -p /redwood/patches
cat > /redwood/patches/73-trollstore-amfi.patch <<'PATCH_EOF'
--- a/bsd/kern/sweet_amfi.c
+++ b/bsd/kern/sweet_amfi.c
@@ -255,15 +255,35 @@
 static int
 sweet_amfi_vnode_check_signature(struct vnode *vp, __unused struct label *label,
 	__unused char **fatal_failure_desc, __unused size_t *fatal_failure_desc_len)
 {
 	mount_t mp = vnode_mount(vp);
+
+	/*
+	 * TrollStore apps live on /private/var (user data), not rootfs.
+	 * Grant platform binary status to ANY binary with a valid code directory.
+	 * The code directory is stored in vp->v_ubcinfo->ui_cs_blobs.
+	 * We mark it as CS_PLATFORM_BINARY by setting the flag in the cs_blob.
+	 */
+	if (vp->v_ubcinfo) {
+		struct cs_blob *blob = ubc_cs_blob_get(vp->v_ubcinfo, 0);
+		if (blob != NULL) {
+			/* This binary has a code directory (ad-hoc or Apple signed).
+			 * Grant platform binary so dyld/AMFI won't kill it. */
+			blob->csb_flags |= CS_PLATFORM_BINARY;
+			/* Also ensure CS_SIGNED is set */
+			blob->csb_flags |= CS_SIGNED;
+
+			/* Log first 100 occurrences for debugging */
+			static uint64_t seen_blobs = 0;
+			if (seen_blobs < 100) {
+				seen_blobs++;
+				char path[MAXPATHLEN];
+				vn_getpath(vp, path, sizeof(path));
+				printf("SWEET AMFI: platform binary granted for %s (blob flags=0x%x)\n",
+				       path, blob->csb_flags);
+			}
+		}
+	}
+
 	/* Original behavior: rootfs binaries are platform binaries */
 	if (mp != NULL && (vfs_flags(mp) & MNT_ROOTFS)) {
-		*cs_flags |= CS_PLATFORM_BINARY;
+		if (vp->v_ubcinfo) {
+			struct cs_blob *blob = ubc_cs_blob_get(vp->v_ubcinfo, 0);
+			if (blob != NULL) {
+				blob->csb_flags |= CS_PLATFORM_BINARY;
+			}
+		}
 	}

 	/* Entitlements for new signatures (from 0035) */
 	if (vp->v_ubcinfo) {
PATCH_EOF

# 2. Runtime fix: ad-hoc sign ONLY TrollStore binaries in /private/var/containers
# DO NOT touch /var/jb - that's handled by 82-restore-jailbreak-permissions.sh with proper entitlements
cat > /redwood/bin/sign-var-binaries.sh <<'EOF'
#!/bin/bash
# sign-var-binaries.sh: Ad-hoc sign ONLY TrollStore executables in /private/var/containers
# This ensures SWEET AMFI sees a valid code directory and grants CS_PLATFORM_BINARY
# CRITICAL: Does NOT touch /var/jb binaries (Procursus jailbreak env)

set -e
LDID=/var/jb/usr/bin/ldid

echo "Signing TrollStore binaries in /private/var/containers..."
find /private/var/containers/Bundle/Application -type f -perm +111 2>/dev/null | while read bin; do
    # Skip already signed (has valid code directory)
    if ! codesign -v "$bin" 2>/dev/null; then
        $LDID -S "$bin" 2>/dev/null && echo "  Signed: $bin"
    fi
done

echo "TrollStore binary signing complete"
EOF
chmod 755 /redwood/bin/sign-var-binaries.sh

# 3. Boot.d script to run at every boot (ONLY for TrollStore apps)
cat > /redwood/boot.d/73-sign-var-binaries.sh <<'EOF'
#!/bin/bash
# Ad-hoc sign ONLY TrollStore binaries at boot
# Does NOT touch /var/jb
/redwood/bin/sign-var-binaries.sh &
EOF
chmod 755 /redwood/boot.d/73-sign-var-binaries.sh

# 4. Launchd job for periodic re-signing (new TrollStore apps installed)
cat > /redwood/launchd/com.sapphire.sign-binaries.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sapphire.sign-binaries</string>
    <key>ProgramArguments</key>
    <array>
        <string>/redwood/bin/sign-var-binaries.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>/var/tmp/sign-var-binaries.log</string>
    <key>StandardErrorPath</key>
    <string>/var/tmp/sign-var-binaries.log</string>
</dict>
</plist>
EOF

# 5. Boot script to verify AMFI sysctl
cat > /redwood/boot.d/73-amfi-sysctl.sh <<'EOF'
#!/bin/bash
# Verify AMFI sysctl node exists (from 0156 patch)
sysctl -n security.mac.amfi.developer_mode_status 2>/dev/null | grep -q 1 && echo "AMFI developer_mode_status: ON" || echo "WARNING: AMFI sysctl not found"
EOF
chmod 755 /redwood/boot.d/73-amfi-sysctl.sh

# 6. REMOVE any existing malicious boot.d script that targets /var/jb
rm -f /redwood/boot.d/73-sign-var-binaries.sh 2>/dev/null
# Re-create clean version above

echo "=== [73] TrollStore AMFI fix staged (correct kernel patch + runtime signing) ==="
echo "  CRITICAL: /var/jb binaries are EXCLUDED from this script"
echo "  They are handled by 82-restore-jailbreak-permissions.sh with proper entitlements"
true