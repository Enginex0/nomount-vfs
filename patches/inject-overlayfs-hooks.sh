#!/bin/bash
# inject-overlayfs-hooks.sh - Inject NoMount OverlayFS stat re-spoofing hooks
# Part of the NoMount VFS kernel patch system
#
# PROBLEM: OverlayFS bypasses NoMount stat spoofing in fs/stat.c
#
# The bypass mechanism:
#   1. User calls stat("/system/etc/audio_effects.conf")
#   2. OverlayFS ovl_getattr() calls vfs_getattr() on the real file
#   3. vfs_getattr() triggers NoMount hooks - stat->dev spoofed to 253:5
#   4. ovl_map_dev_ino() OVERWRITES stat->dev with overlay's s_dev (253:47)
#   5. Result: spoofing is LOST, Gboard sees wrong device ID and crashes
#
# SOLUTION: Inject a hook AFTER ovl_map_dev_ino() to re-apply spoofing
#
# Usage: ./inject-overlayfs-hooks.sh [path/to/inode.c]
# Default: fs/overlayfs/inode.c

set -e

TARGET="${1:-fs/overlayfs/inode.c}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Verify target file exists
if [[ ! -f "$TARGET" ]]; then
    error "Target file not found: $TARGET"
fi

info "Injecting NoMount OverlayFS hooks into: $TARGET"

# ============================================================================
# INJECTION 1: Include directive for vfs_dcache.h
# ============================================================================
inject_include() {
    local marker="linux/vfs_dcache.h"

    if grep -q "$marker" "$TARGET"; then
        info "Include already injected (found $marker), skipping."
        return 0
    fi

    # Primary anchor: #include "overlayfs.h"
    # This is the local header included at the end of the include block
    local anchor=""
    if grep -q '#include "overlayfs.h"' "$TARGET"; then
        anchor='#include "overlayfs.h"'
        info "Using primary anchor: $anchor"
    elif grep -q '#include <linux/fiemap.h>' "$TARGET"; then
        anchor='#include <linux/fiemap.h>'
        info "Using fallback anchor: $anchor"
    else
        error "No suitable anchor found for include injection"
    fi

    info "Injecting include directive..."

    # Inject after anchor
    sed -i "/${anchor//\//\\/}/a\\
#ifdef CONFIG_FS_DCACHE_PREFETCH\\
#include <linux/vfs_dcache.h>\\
#endif" "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject include directive"
    fi

    info "Include directive injected successfully."
}

# ============================================================================
# INJECTION 2: Hook in ovl_getattr() AFTER ovl_map_dev_ino() call
# ============================================================================
inject_ovl_getattr_hook() {
    local marker="nomount_ovl_hook"  # Unique marker for this hook

    if grep -q "$marker" "$TARGET"; then
        info "ovl_getattr hook already injected, skipping."
        return 0
    fi

    # Find the anchor pattern: the ovl_map_dev_ino call and its error check
    # Line 253-255 in the original:
    #   err = ovl_map_dev_ino(dentry, stat, fsid);
    #   if (err)
    #       goto out;
    #
    # We inject AFTER "goto out;" following ovl_map_dev_ino error check

    # Verify the anchor pattern exists
    if ! grep -q 'err = ovl_map_dev_ino(dentry, stat, fsid);' "$TARGET"; then
        error "Anchor pattern 'err = ovl_map_dev_ino(dentry, stat, fsid);' not found in $TARGET"
    fi

    # Also verify the error check follows
    if ! grep -A2 'err = ovl_map_dev_ino(dentry, stat, fsid);' "$TARGET" | grep -q 'goto out;'; then
        warn "Expected 'goto out;' after ovl_map_dev_ino error check not found"
        warn "Will attempt injection anyway..."
    fi

    info "Injecting ovl_getattr hook after ovl_map_dev_ino()..."

    # We need to inject after the "goto out;" that follows the ovl_map_dev_ino error check
    # Use a more precise sed pattern that matches the specific context
    #
    # The pattern we're looking for is:
    #   err = ovl_map_dev_ino(dentry, stat, fsid);
    #   if (err)
    #       goto out;
    #
    # We want to inject after this block

    # Create a temporary file for the complex injection
    local tmp_file=$(mktemp)

    # Use awk for more precise multi-line pattern matching and injection
    awk '
    /err = ovl_map_dev_ino\(dentry, stat, fsid\);/ {
        found_map_dev_ino = 1
    }
    found_map_dev_ino && /goto out;/ && !injected {
        print
        print ""
        print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
        print "\t/* NoMount OverlayFS Hook (nomount_ovl_hook) */"
        print "\t/* Re-spoof stat after ovl_map_dev_ino() overwrites device ID */"
        print "\t{"
        print "\t\tstruct dentry *__nm_real_dentry = ovl_dentry_real(dentry);"
        print "\t\tstruct inode *__nm_real_inode = __nm_real_dentry ? d_inode(__nm_real_dentry) : NULL;"
        print "\t\tdev_t __nm_dev_before = stat->dev;"
        print "\t\tino_t __nm_ino_before = stat->ino;"
        print ""
        print "\t\tpr_info(\"nomount: [OVL_HOOK] ovl_getattr ENTER dentry=%s\\n\","
        print "\t\t\tdentry->d_name.name);"
        print "\t\tpr_info(\"nomount: [OVL_HOOK] real_dentry=%p real_inode=%p\\n\","
        print "\t\t\t__nm_real_dentry, __nm_real_inode);"
        print ""
        print "\t\tif (__nm_real_inode) {"
        print "\t\t\tpr_info(\"nomount: [OVL_HOOK] real_inode ino=%lu dev=%u:%u\\n\","
        print "\t\t\t\t__nm_real_inode->i_ino,"
        print "\t\t\t\tMAJOR(__nm_real_inode->i_sb->s_dev),"
        print "\t\t\t\tMINOR(__nm_real_inode->i_sb->s_dev));"
        print "\t\t\tpr_info(\"nomount: [OVL_HOOK] stat AFTER ovl_map_dev_ino: dev=%u:%u ino=%lu\\n\","
        print "\t\t\t\tMAJOR(stat->dev), MINOR(stat->dev), stat->ino);"
        print ""
        print "\t\t\tif (nomount_is_injected_file(__nm_real_inode)) {"
        print "\t\t\t\tpr_info(\"nomount: [OVL_HOOK] IS_INJECTED=true, calling nomount_spoof_stat\\n\");"
        print "\t\t\t\tnomount_spoof_stat(__nm_real_inode, stat);"
        print "\t\t\t\tpr_info(\"nomount: [OVL_HOOK] AFTER spoof: dev=%u:%u ino=%lu\\n\","
        print "\t\t\t\t\tMAJOR(stat->dev), MINOR(stat->dev), stat->ino);"
        print ""
        print "\t\t\t\tif (__nm_dev_before != stat->dev || __nm_ino_before != stat->ino) {"
        print "\t\t\t\t\tpr_info(\"nomount: [OVL_HOOK] SPOOFED dev %u:%u->%u:%u ino %lu->%lu\\n\","
        print "\t\t\t\t\t\tMAJOR(__nm_dev_before), MINOR(__nm_dev_before),"
        print "\t\t\t\t\t\tMAJOR(stat->dev), MINOR(stat->dev),"
        print "\t\t\t\t\t\t__nm_ino_before, stat->ino);"
        print "\t\t\t\t}"
        print "\t\t\t} else {"
        print "\t\t\t\tpr_info(\"nomount: [OVL_HOOK] IS_INJECTED=false, no spoofing needed\\n\");"
        print "\t\t\t}"
        print "\t\t} else {"
        print "\t\t\tpr_info(\"nomount: [OVL_HOOK] real_inode is NULL, cannot spoof\\n\");"
        print "\t\t}"
        print "\t}"
        print "#endif"
        injected = 1
        next
    }
    { print }
    ' "$TARGET" > "$tmp_file"

    # Check if injection was successful
    if ! grep -q "$marker" "$tmp_file"; then
        rm -f "$tmp_file"
        error "AWK injection failed - marker not found in output"
    fi

    # Replace original file
    mv "$tmp_file" "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject ovl_getattr hook"
    fi

    info "ovl_getattr hook injected successfully."
}

# ============================================================================
# Main execution
# ============================================================================
info "============================================================"
info "NoMount OverlayFS Hook Injection Script"
info "============================================================"
info ""
info "This script injects a hook into ovl_getattr() to re-apply"
info "stat spoofing AFTER ovl_map_dev_ino() overwrites device IDs."
info ""

inject_include
inject_ovl_getattr_hook

info ""
info "============================================================"
info "All NoMount OverlayFS hooks injected successfully into $TARGET"
info "============================================================"
exit 0
