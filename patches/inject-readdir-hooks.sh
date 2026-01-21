#!/bin/bash
#
# inject-readdir-hooks.sh - Inject NoMount hooks into fs/readdir.c
#
# Usage: ./inject-readdir-hooks.sh <path-to-readdir.c>
#
# This script uses sed to inject NoMount VFS hooks at specific locations
# in the kernel's readdir.c file for directory listing interception.
#

set -e

READDIR_FILE="${1:-fs/readdir.c}"

if [ ! -f "$READDIR_FILE" ]; then
    echo "Error: File not found: $READDIR_FILE"
    exit 1
fi

echo "Injecting NoMount readdir hooks into: $READDIR_FILE"

# Check if already patched
if grep -q "CONFIG_FS_DCACHE_PREFETCH" "$READDIR_FILE"; then
    echo "File already contains NoMount hooks (CONFIG_FS_DCACHE_PREFETCH found). Skipping."
    exit 0
fi

#
# INJECTION 1: Include header after #include <linux/uaccess.h>
#
echo "  [1/3] Injecting vfs_dcache.h include..."
sed -i '/#include <linux\/uaccess.h>/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$READDIR_FILE"

#
# INJECTION 2: Variable declaration in SYSCALL_DEFINE3(getdents64) after "int error;"
#
# We target ONLY the getdents64 syscall by using an address range from
# SYSCALL_DEFINE3(getdents64 to the next function's closing brace pattern.
# The "int error;" line is tab-indented within the function.
#
echo "  [2/3] Injecting initial_count variable in getdents64..."
sed -i '/^SYSCALL_DEFINE3(getdents64,/,/^}$/{
/^	int error;$/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	int initial_count = count;\
#endif
}' "$READDIR_FILE"

#
# INJECTION 3: Hook after "error = buf.error;" but BEFORE "if (buf.prev_reclen)"
#
# Within getdents64, the pattern is:
#   if (error >= 0)
#       error = buf.error;
#   if (buf.prev_reclen) {
#
# We match the double-tab-indented "error = buf.error;" line and append our hook.
#
echo "  [3/3] Injecting nomount_inject_dents64 hook in getdents64..."
sed -i '/^SYSCALL_DEFINE3(getdents64,/,/^}$/{
/^		error = buf\.error;$/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	if (error >= 0 \&\& !signal_pending(current)) {\
		nomount_inject_dents64(f.file, (void __user **)\&dirent, \&count, \&f.file->f_pos);\
		error = initial_count - count;\
	}\
#endif
}' "$READDIR_FILE"

echo "NoMount readdir hooks injection complete."
