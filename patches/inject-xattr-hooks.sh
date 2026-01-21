#!/bin/bash
# inject-xattr-hooks.sh - Inject NoMount xattr spoofing hooks into fs/xattr.c
# Part of the NoMount VFS kernel patch system
#
# Usage: ./inject-xattr-hooks.sh [path/to/xattr.c]
# Default: fs/xattr.c

set -e

TARGET="${1:-fs/xattr.c}"

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

info "Injecting NoMount xattr hooks into: $TARGET"

# ============================================================================
# INJECTION 1: Include directive after linux/uaccess.h
# ============================================================================
inject_include() {
    local marker="linux/vfs_dcache.h"

    if grep -q "$marker" "$TARGET"; then
        info "Include already injected (found $marker), skipping."
        return 0
    fi

    # Anchor: #include <linux/uaccess.h>
    if ! grep -q '#include <linux/uaccess.h>' "$TARGET"; then
        error "Anchor pattern '#include <linux/uaccess.h>' not found in $TARGET"
    fi

    info "Injecting include directive..."

    # Inject after #include <linux/uaccess.h>
    sed -i '/#include <linux\/uaccess.h>/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject include directive"
    fi

    info "Include directive injected successfully."
}

# ============================================================================
# INJECTION 2: Hook in vfs_listxattr() after ssize_t error; declaration
# Spoofs xattr list for injected files - returns only security.selinux
# ============================================================================
inject_vfs_listxattr_hook() {
    local marker="nomount_is_injected_file"

    if grep -q "$marker" "$TARGET"; then
        info "vfs_listxattr hook already injected, skipping."
        return 0
    fi

    # Anchor: The unique pattern in vfs_listxattr()
    # struct inode *inode = d_inode(dentry);
    # ssize_t error;
    if ! grep -q 'struct inode \*inode = d_inode(dentry);' "$TARGET"; then
        error "Anchor pattern 'struct inode *inode = d_inode(dentry);' not found in $TARGET"
    fi

    info "Injecting vfs_listxattr hook..."

    # Inject after the ssize_t error; line that follows the d_inode pattern
    # We match the ssize_t error; line directly - it only appears once in vfs_listxattr context
    sed -i '/^vfs_listxattr/,/^}$/{
        /ssize_t error;$/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	/* Spoof xattr list for injected files - return only security.selinux */\
	if (nomount_is_injected_file(inode)) {\
		static const char spoofed_list[] = XATTR_NAME_SELINUX;\
		size_t list_len = sizeof(spoofed_list);\
		if (size == 0)\
			return list_len;\
		if (size < list_len)\
			return -ERANGE;\
		if (!list)\
			return -EFAULT;\
		memcpy(list, spoofed_list, list_len);\
		return list_len;\
	}\
#endif
    }' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject vfs_listxattr hook"
    fi

    info "vfs_listxattr hook injected successfully."
}

# ============================================================================
# INJECTION 3: Hook in __vfs_getxattr() after int error; declaration
# Spoofs SELinux context for NoMount injected files
# ============================================================================
inject_vfs_getxattr_hook() {
    local marker="vfs_dcache_get_ctx"

    if grep -q "$marker" "$TARGET"; then
        info "__vfs_getxattr hook already injected, skipping."
        return 0
    fi

    # Verify function exists with expected pattern
    if ! grep -q '^__vfs_getxattr' "$TARGET"; then
        error "Function __vfs_getxattr not found in $TARGET"
    fi

    info "Injecting __vfs_getxattr hook..."

    # Inject after the int error; line within __vfs_getxattr function
    # Match from function start to function end, then inject after int error;
    sed -i '/^__vfs_getxattr/,/^}$/{
        /int error;$/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	/* Spoof SELinux context for NoMount injected files */\
	if (name && strcmp(name, XATTR_NAME_SELINUX) == 0) {\
		const char *spoofed_ctx = vfs_dcache_get_ctx(inode);\
		if (spoofed_ctx) {\
			size_t ctx_len = strlen(spoofed_ctx);\
			if (size == 0)\
				return ctx_len;\
			if (ctx_len > size)\
				return -ERANGE;\
			memcpy(value, spoofed_ctx, ctx_len);\
			return ctx_len;\
		}\
	}\
#endif
    }' "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject __vfs_getxattr hook"
    fi

    info "__vfs_getxattr hook injected successfully."
}

# ============================================================================
# Main execution
# ============================================================================
inject_include
inject_vfs_listxattr_hook
inject_vfs_getxattr_hook

info "All NoMount xattr hooks injected successfully into $TARGET"
exit 0
