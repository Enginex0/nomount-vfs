#!/bin/bash
# inject-stat-hooks.sh - Inject NoMount stat spoofing hooks into fs/stat.c
# Part of the NoMount VFS kernel patch system
#
# Usage: ./inject-stat-hooks.sh [path/to/stat.c]
# Default: fs/stat.c

set -e

TARGET="${1:-fs/stat.c}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Verify target file exists
if [[ ! -f "$TARGET" ]]; then
    error "Target file not found: $TARGET"
fi

info "Injecting NoMount stat hooks into: $TARGET"

# ============================================================================
# INJECTION 1: Include directive after asm/unaligned.h (or mount.h fallback)
# ============================================================================
inject_include() {
    local marker="linux/vfs_dcache.h"

    if grep -q "$marker" "$TARGET"; then
        info "Include already injected (found $marker), skipping."
        return 0
    fi

    # Primary anchor: #include <asm/unaligned.h>
    # Fallback anchor: #include "mount.h"
    local anchor=""
    if grep -q '#include <asm/unaligned.h>' "$TARGET"; then
        anchor='#include <asm/unaligned.h>'
        info "Using primary anchor: $anchor"
    elif grep -q '#include "mount.h"' "$TARGET"; then
        anchor='#include "mount.h"'
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
# INJECTION 2: Hook in generic_fillattr() after stat->ino = inode->i_ino;
# ============================================================================
inject_generic_fillattr_hook() {
    local marker="nomount_is_injected_file"

    if grep -q "$marker" "$TARGET"; then
        info "generic_fillattr hook already injected, skipping."
        return 0
    fi

    # Find anchor: stat->ino = inode->i_ino;
    if ! grep -q 'stat->ino = inode->i_ino;' "$TARGET"; then
        error "Anchor pattern 'stat->ino = inode->i_ino;' not found in $TARGET"
    fi

    info "Injecting generic_fillattr hook..."

    # Inject after stat->ino = inode->i_ino;
    sed -i '/stat->ino = inode->i_ino;/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (nomount_is_injected_file(inode)) {\
		dev_t __gf_dev_before = stat->dev;\
		ino_t __gf_ino_before = stat->ino;\
		pr_info("nomount: [HOOK] generic_fillattr ENTER ino=%lu dev=%u:%u uid=%u\\n", inode->i_ino, MAJOR(stat->dev), MINOR(stat->dev), current_uid().val);\
		nomount_spoof_stat(inode, stat);\
		pr_info("nomount: [HOOK] generic_fillattr AFTER dev=%u:%u ino=%lu\\n", MAJOR(stat->dev), MINOR(stat->dev), stat->ino);\
		if (__gf_dev_before != stat->dev || __gf_ino_before != stat->ino) {\
			pr_info("nomount: [HOOK] generic_fillattr CHANGED dev=%u:%u->%u:%u ino=%lu->%lu\\n", MAJOR(__gf_dev_before), MINOR(__gf_dev_before), MAJOR(stat->dev), MINOR(stat->dev), __gf_ino_before, stat->ino);\
		}\
	}\
#endif' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject generic_fillattr hook"
    fi

    info "generic_fillattr hook injected successfully."
}

# ============================================================================
# INJECTION 3: Hook in vfs_getattr_nosec() - WRAP the inode->i_op->getattr path
# This is the PRIMARY hook - fires AFTER ovl_getattr() for OverlayFS files
# ============================================================================
inject_vfs_getattr_nosec_getattr_hook() {
    local marker="__nm_getattr_ret"

    if grep -q "$marker" "$TARGET"; then
        info "vfs_getattr_nosec getattr-path hook already injected, skipping."
        return 0
    fi

    # We need to replace the early-return pattern:
    #   if (inode->i_op->getattr)
    #       return inode->i_op->getattr(path, stat, request_mask,
    #                                   query_flags);
    #
    # With a wrapped version that stores the result, hooks on success, then returns.

    if ! grep -q 'if (inode->i_op->getattr)' "$TARGET"; then
        error "Anchor pattern 'if (inode->i_op->getattr)' not found in $TARGET"
    fi

    info "Injecting vfs_getattr_nosec getattr-path hook (post-getattr position)..."

    # Use sed to replace the if-return pattern with wrapped version
    # Match: if (inode->i_op->getattr)\n\t\treturn inode->i_op->getattr(
    # Note: The actual return spans 2 lines due to line continuation
    sed -i '/if (inode->i_op->getattr)$/{
N
N
s/if (inode->i_op->getattr)\n\t\treturn inode->i_op->getattr(path, stat, request_mask,\n\t\t\t\t\t    query_flags);/if (inode->i_op->getattr) {\
		int __nm_getattr_ret = inode->i_op->getattr(path, stat, request_mask,\
						    query_flags);\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
		if (__nm_getattr_ret == 0) {\
			char *__nm_buf = (char *)__get_free_page(GFP_KERNEL);\
			if (__nm_buf) {\
				char *__nm_path = d_path(path, __nm_buf, PAGE_SIZE);\
				if (!IS_ERR(__nm_path)) {\
					dev_t __nm_dev_before = stat->dev;\
					ino_t __nm_ino_before = stat->ino;\
					vfs_dcache_spoof_stat_dev(__nm_path, stat);\
					if (__nm_dev_before != stat->dev || __nm_ino_before != stat->ino) {\
						pr_info("nomount: [HOOK] vfs_getattr_nosec(getattr) CHANGED path=%s dev=%u:%u->%u:%u ino=%lu->%lu\\n", __nm_path, MAJOR(__nm_dev_before), MINOR(__nm_dev_before), MAJOR(stat->dev), MINOR(stat->dev), __nm_ino_before, stat->ino);\
					}\
				}\
				free_page((unsigned long)__nm_buf);\
			}\
		}\
#endif\
		return __nm_getattr_ret;\
	}/
}' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject vfs_getattr_nosec getattr-path hook"
    fi

    info "vfs_getattr_nosec getattr-path hook injected successfully."
}

# ============================================================================
# INJECTION 4: Hook in vfs_getattr_nosec() after generic_fillattr(inode, stat);
# This is the FALLBACK hook - fires for simple inodes without custom getattr
# ============================================================================
inject_vfs_getattr_nosec_fillattr_hook() {
    local marker="__nm_fillattr_spoof_done"

    if grep -q "$marker" "$TARGET"; then
        info "vfs_getattr_nosec fillattr-path hook already injected, skipping."
        return 0
    fi

    # Find anchor: generic_fillattr(inode, stat);
    # This appears only once in vfs_getattr_nosec()
    if ! grep -q 'generic_fillattr(inode, stat);' "$TARGET"; then
        error "Anchor pattern 'generic_fillattr(inode, stat);' not found in $TARGET"
    fi

    info "Injecting vfs_getattr_nosec fillattr-path hook..."

    # Inject after generic_fillattr(inode, stat);
    sed -i '/generic_fillattr(inode, stat);/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	/* __nm_fillattr_spoof_done - marker for idempotency */\
	{\
		char *__nm_buf = (char *)__get_free_page(GFP_KERNEL);\
		if (__nm_buf) {\
			char *__nm_path = d_path(path, __nm_buf, PAGE_SIZE);\
			if (!IS_ERR(__nm_path)) {\
				dev_t __nm_dev_before = stat->dev;\
				ino_t __nm_ino_before = stat->ino;\
				vfs_dcache_spoof_stat_dev(__nm_path, stat);\
				if (__nm_dev_before != stat->dev || __nm_ino_before != stat->ino) {\
					pr_info("nomount: [HOOK] vfs_getattr_nosec(fillattr) CHANGED path=%s dev=%u:%u->%u:%u ino=%lu->%lu\\n", __nm_path, MAJOR(__nm_dev_before), MINOR(__nm_dev_before), MAJOR(stat->dev), MINOR(stat->dev), __nm_ino_before, stat->ino);\
				}\
			}\
			free_page((unsigned long)__nm_buf);\
		}\
	}\
#endif' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject vfs_getattr_nosec fillattr-path hook"
    fi

    info "vfs_getattr_nosec fillattr-path hook injected successfully."
}

# ============================================================================
# Main execution
# ============================================================================
inject_include
inject_generic_fillattr_hook
inject_vfs_getattr_nosec_getattr_hook
inject_vfs_getattr_nosec_fillattr_hook

info "All NoMount stat hooks injected successfully into $TARGET"
exit 0
