#!/bin/bash
# inject-procmounts-hooks.sh - Injects NoMount mount hiding hooks into fs/proc_namespace.c
# Usage: ./inject-procmounts-hooks.sh <path/to/proc_namespace.c>
#
# This script uses sed to inject CONFIG_FS_DCACHE_PREFETCH hooks that hide
# mounts from /proc/<pid>/mounts, /proc/<pid>/mountinfo, and /proc/<pid>/mountstats

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path/to/proc_namespace.c>"
    exit 1
fi

TARGET="$1"

if [ ! -f "$TARGET" ]; then
    echo "Error: File not found: $TARGET"
    exit 1
fi

# Check if already injected
if grep -q "vfs_dcache_is_mount_hidden" "$TARGET"; then
    echo "Hooks already present in $TARGET"
    exit 0
fi

# Verify required patterns exist
if ! grep -q '#include "internal.h"' "$TARGET"; then
    echo "Error: Pattern '#include \"internal.h\"' not found"
    exit 1
fi

if ! grep -q 'static int show_vfsmnt' "$TARGET"; then
    echo "Error: Function 'show_vfsmnt' not found"
    exit 1
fi

if ! grep -q 'static int show_mountinfo' "$TARGET"; then
    echo "Error: Function 'show_mountinfo' not found"
    exit 1
fi

if ! grep -q 'static int show_vfsstat' "$TARGET"; then
    echo "Error: Function 'show_vfsstat' not found"
    exit 1
fi

# Define the hook code block (with proper tab indentation)
read -r -d '' HOOK_CODE << 'HOOKEOF' || true
#ifdef CONFIG_FS_DCACHE_PREFETCH
	{
		struct mount *__nm_r = real_mount(mnt);
		if (vfs_dcache_is_mount_hidden(__nm_r->mnt_id))
			return 0;
	}
#endif
HOOKEOF

# 1. Inject include after '#include "internal.h"'
# Match the line and append the include block
sed -i '/#include "internal.h"$/a\
\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"

# 2. Inject hook in show_vfsmnt() - before 'if (sb->s_op->show_devname)'
# This pattern is unique: it's the first occurrence after show_vfsmnt function
# Use address range: find show_vfsmnt, then find first 'if (sb->s_op->show_devname)'
sed -i '/^static int show_vfsmnt/,/^static int show_mountinfo/{
    /if (sb->s_op->show_devname) {$/i\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	{\
		struct mount *__nm_r = real_mount(mnt);\
		if (vfs_dcache_is_mount_hidden(__nm_r->mnt_id))\
			return 0;\
	}\
#endif\

}' "$TARGET"

# 3. Inject hook in show_mountinfo() - before 'seq_printf(m, "%i %i %u:%u'
# This pattern is unique in the file
sed -i '/seq_printf(m, "%i %i %u:%u /i\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	{\
		struct mount *__nm_r = real_mount(mnt);\
		if (vfs_dcache_is_mount_hidden(__nm_r->mnt_id))\
			return 0;\
	}\
#endif\
' "$TARGET"

# 4. Inject hook in show_vfsstat() - before '/* device */'
# This comment pattern is unique in the file
sed -i '/\/\* device \*\//i\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
	{\
		struct mount *__nm_r = real_mount(mnt);\
		if (vfs_dcache_is_mount_hidden(__nm_r->mnt_id))\
			return 0;\
	}\
#endif\
' "$TARGET"

echo "Successfully injected NoMount hooks into $TARGET"
