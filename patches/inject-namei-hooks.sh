#!/bin/bash
#
# inject-namei-hooks.sh - Inject NoMount hooks into fs/namei.c
#
# Usage: ./inject-namei-hooks.sh <path-to-namei.c>
#
# This script uses sed to inject NoMount VFS hooks at specific locations
# in the kernel's namei.c file.
#

set -e

NAMEI_FILE="$1"

if [ -z "$NAMEI_FILE" ]; then
    echo "Usage: $0 <path-to-namei.c>"
    exit 1
fi

if [ ! -f "$NAMEI_FILE" ]; then
    echo "Error: File not found: $NAMEI_FILE"
    exit 1
fi

echo "Injecting NoMount hooks into: $NAMEI_FILE"

# Check if already patched
if grep -q "CONFIG_FS_DCACHE_PREFETCH" "$NAMEI_FILE"; then
    echo "File already contains NoMount hooks (CONFIG_FS_DCACHE_PREFETCH found). Skipping."
    exit 0
fi

#
# INJECTION 1: Include header after #include "mount.h"
#
echo "  [1/5] Injecting vfs_dcache.h include..."
sed -i '/#include "mount.h"/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$NAMEI_FILE"

#
# INJECTION 2: Hook in getname_flags() after audit_getname(result);
#
# Pattern: audit_getname(result); followed by return result; (unique to getname_flags)
#
echo "  [2/5] Injecting getname_flags() hook..."
sed -i '/audit_getname(result);/{
N
/\n[[:space:]]*return result;/s/audit_getname(result);/audit_getname(result);\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (!IS_ERR(result)) {\
		result = nomount_getname_hook(result);\
	}\
#endif\
/
}' "$NAMEI_FILE"

#
# INJECTION 3: Hook in generic_permission() after int ret; declaration
#
echo "  [3/5] Injecting generic_permission() hook..."
sed -i '/^int generic_permission(struct inode \*inode, int mask)$/,/^}$/{
/^{$/,/int ret;/{
/int ret;/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (nomount_is_injected_file(inode))\
		return 0;\
	if (S_ISDIR(inode->i_mode) \&\& nomount_is_traversal_allowed(inode, mask))\
		return 0;\
#endif
}
}' "$NAMEI_FILE"

#
# INJECTION 4: Hook in inode_permission() after int retval; declaration
#
echo "  [4/5] Injecting inode_permission() hook..."
sed -i '/^int inode_permission(struct inode \*inode, int mask)$/,/^}$/{
/^{$/,/int retval;/{
/int retval;/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (nomount_is_injected_file(inode))\
		return 0;\
	if (S_ISDIR(inode->i_mode) \&\& nomount_is_traversal_allowed(inode, mask))\
		return 0;\
#endif
}
}' "$NAMEI_FILE"

#
# INJECTION 5: Hook in vfs_readlink() after int res; declaration
#
echo "  [5/5] Injecting vfs_readlink() hook..."
sed -i '/^int vfs_readlink(struct dentry \*dentry, char __user \*buffer, int buflen)$/,/^}$/{
/int res;/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (nomount_is_injected_file(inode)) {\
		DEFINE_DELAYED_CALL(nm_done);\
		const char *nm_link;\
		bool need_cleanup = false;\
		nm_link = READ_ONCE(inode->i_link);\
		if (!nm_link \&\& inode->i_op \&\& inode->i_op->get_link) {\
			nm_link = inode->i_op->get_link(dentry, inode, \&nm_done);\
			if (IS_ERR(nm_link))\
				return PTR_ERR(nm_link);\
			need_cleanup = true;\
		}\
		if (nm_link) {\
			const char *sanitized = NULL;\
			const char *mod_prefix = strnstr(nm_link, "/data/adb/modules/", PATH_MAX);\
			const char *debug_prefix = strnstr(nm_link, "/debug_ramdisk/", PATH_MAX);\
			if (mod_prefix) {\
				const char *after_modules = mod_prefix + 18;\
				sanitized = strchr(after_modules, '"'"'/'"'"');\
			} else if (debug_prefix) {\
				sanitized = debug_prefix + 14;\
			}\
			if (sanitized) {\
				res = readlink_copy(buffer, buflen, sanitized);\
				if (need_cleanup)\
					do_delayed_call(\&nm_done);\
				return res;\
			}\
			if (need_cleanup)\
				do_delayed_call(\&nm_done);\
		}\
	}\
#endif
}' "$NAMEI_FILE"

echo "NoMount hooks injection complete."
