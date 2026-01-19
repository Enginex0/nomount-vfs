#!/bin/bash
# NoMount fs/d_path.c hook injection script
# Injects virtual path spoofing into d_path() to hide redirected file paths
# This fixes /proc/self/fd symlink resolution leak where readlink() reveals the real path
#
# Usage: ./inject-procfd-hooks.sh /path/to/kernel/fs/d_path.c

set -e

TARGET="$1"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: File not found: $TARGET"
    exit 1
fi

# Check if already patched
if grep -q "nomount_get_virtual_path_for_inode" "$TARGET"; then
    echo "INFO: d_path.c already has NoMount hooks"
    exit 0
fi

echo "Injecting NoMount virtual path spoofing hooks into $TARGET..."

# Create backup
cp "$TARGET" "${TARGET}.backup"

# Add include after prefetch.h or mount.h
if ! grep -q "linux/vfs_dcache.h" "$TARGET"; then
    if grep -q '#include "mount.h"' "$TARGET"; then
        sed -i '/#include "mount.h"/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"
    elif grep -q '#include <linux/prefetch.h>' "$TARGET"; then
        sed -i '/#include <linux\/prefetch.h>/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"
    else
        echo "ERROR: Could not find suitable location for include"
        mv "${TARGET}.backup" "$TARGET"
        exit 1
    fi
    echo "  Added vfs_dcache.h include"
fi

# Use AWK to inject hook at the START of d_path function
# The hook intercepts path-to-string conversion and returns virtual path if redirected
awk '
BEGIN {
    in_func = 0
    brace_depth = 0
    injected = 0
    found_func_start = 0
}

# Detect d_path function signature
/^char \*d_path\(const struct path \*path, char \*buf, int buflen\)/ ||
/^char \*d_path\(struct path \*path, char \*buf, int buflen\)/ {
    in_func = 1
    found_func_start = 1
}

# Track brace depth when inside function
in_func == 1 && /\{/ {
    n = gsub(/\{/, "{")
    brace_depth += n

    # Inject right after the opening brace of d_path
    if (found_func_start == 1 && brace_depth == 1 && injected == 0) {
        print
        print ""
        print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
        print "\t/* Hook: Return virtual path for NoMount-redirected files */"
        print "\t/* This fixes /proc/self/fd symlink resolution leak */"
        print "\tif (path->dentry && path->dentry->d_inode) {"
        print "\t\tchar *v_path = nomount_get_virtual_path_for_inode(path->dentry->d_inode);"
        print "\t\tif (v_path) {"
        print "\t\t\tint len = strlen(v_path);"
        print "\t\t\tchar *res;"
        print "\t\t\tif (buflen < len + 1) {"
        print "\t\t\t\tkfree(v_path);"
        print "\t\t\t\treturn ERR_PTR(-ENAMETOOLONG);"
        print "\t\t\t}"
        print "\t\t\tres = buf + buflen;"
        print "\t\t\t*--res = '\\0';"
        print "\t\t\tres -= len;"
        print "\t\t\tmemcpy(res, v_path, len);"
        print "\t\t\tkfree(v_path);"
        print "\t\t\treturn res;"
        print "\t\t}"
        print "\t}"
        print "#endif"
        print ""
        injected = 1
        found_func_start = 0
        next
    }
}

in_func == 1 && /\}/ {
    n = gsub(/\}/, "}")
    brace_depth -= n
    if (brace_depth <= 0) {
        in_func = 0
        brace_depth = 0
    }
}

{ print }

END {
    if (injected == 0) {
        print "WARNING: Hook not injected - d_path function not found or already modified" > "/dev/stderr"
    }
}
' "$TARGET" > "${TARGET}.new"

mv "${TARGET}.new" "$TARGET"

# Verify injection succeeded
hook_count=$(grep -c 'nomount_get_virtual_path_for_inode' "$TARGET" || true)
if [ "$hook_count" -ge 1 ]; then
    echo "  SUCCESS: virtual path spoof hook injected"
    rm -f "${TARGET}.backup"
else
    echo "  ERROR: Hook injection failed"
    echo "  Restoring backup..."
    mv "${TARGET}.backup" "$TARGET"
    exit 1
fi

echo "Done: virtual path spoof hook injected into d_path()"
echo ""
echo "This hook intercepts /proc/self/fd/N symlink resolution and returns"
echo "the virtual path instead of the real path for NoMount-redirected files."
