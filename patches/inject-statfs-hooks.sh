#!/bin/bash
# inject-statfs-hooks.sh - Injects NoMount statfs spoofing hooks into fs/statfs.c
# Part of the NoMount kernel patch system

set -e

# Target file (default: fs/statfs.c)
TARGET="${1:-fs/statfs.c}"

echo "[INFO] NoMount statfs hook injection script"
echo "[INFO] Target file: $TARGET"

# Check if file exists
if [ ! -f "$TARGET" ]; then
    echo "[ERROR] Target file does not exist: $TARGET"
    exit 1
fi

# Check if hooks already injected (idempotent)
if grep -q "nomount_spoof_statfs" "$TARGET"; then
    echo "[INFO] Hooks already present in $TARGET - skipping injection"
    exit 0
fi

echo "[INFO] Injecting NoMount statfs hooks..."

# Backup original file
cp "$TARGET" "${TARGET}.orig"

# ==============================================================================
# INJECTION 1: Include after #include "internal.h"
# ==============================================================================
echo "[INFO] Injecting include directive..."

sed -i '/#include "internal\.h"/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"

# Verify injection 1
if ! grep -q '#include <linux/vfs_dcache.h>' "$TARGET"; then
    echo "[ERROR] Failed to inject include directive"
    mv "${TARGET}.orig" "$TARGET"
    exit 1
fi
echo "[OK] Include directive injected"

# ==============================================================================
# INJECTION 2: Hook in user_statfs() after error = vfs_statfs(&path, st);
# ==============================================================================
echo "[INFO] Injecting user_statfs hook..."

# The pattern "error = vfs_statfs(&path, st);" is unique to user_statfs
sed -i '/error = vfs_statfs(\&path, st);/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
		/* Spoof statfs for NoMount redirected files */\
		if (!error \&\& path.dentry \&\& d_backing_inode(path.dentry))\
			nomount_spoof_statfs(d_backing_inode(path.dentry), st);\
#endif' "$TARGET"

# Verify injection 2 - check for the specific user_statfs pattern
if ! grep -q 'nomount_spoof_statfs(d_backing_inode(path.dentry), st)' "$TARGET"; then
    echo "[ERROR] Failed to inject user_statfs hook"
    mv "${TARGET}.orig" "$TARGET"
    exit 1
fi
echo "[OK] user_statfs hook injected"

# ==============================================================================
# INJECTION 3: Hook in fd_statfs() after error = vfs_statfs(&f.file->f_path, st);
# ==============================================================================
echo "[INFO] Injecting fd_statfs hook..."

# The pattern "error = vfs_statfs(&f.file->f_path, st);" is unique to fd_statfs
sed -i '/error = vfs_statfs(\&f\.file->f_path, st);/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
		/* Spoof statfs for NoMount redirected files */\
		if (!error \&\& f.file->f_path.dentry \&\& d_backing_inode(f.file->f_path.dentry))\
			nomount_spoof_statfs(d_backing_inode(f.file->f_path.dentry), st);\
#endif' "$TARGET"

# Verify injection 3 - check for the specific fd_statfs pattern
if ! grep -q 'nomount_spoof_statfs(d_backing_inode(f.file->f_path.dentry), st)' "$TARGET"; then
    echo "[ERROR] Failed to inject fd_statfs hook"
    mv "${TARGET}.orig" "$TARGET"
    exit 1
fi
echo "[OK] fd_statfs hook injected"

# ==============================================================================
# Final verification
# ==============================================================================
echo "[INFO] Verifying all hooks..."

# Count occurrences of nomount_spoof_statfs (should be 2)
COUNT=$(grep -c "nomount_spoof_statfs" "$TARGET")
if [ "$COUNT" -ne 2 ]; then
    echo "[ERROR] Expected 2 hook calls, found $COUNT"
    mv "${TARGET}.orig" "$TARGET"
    exit 1
fi

# Count occurrences of vfs_dcache.h include (should be 1)
INCLUDE_COUNT=$(grep -c 'include <linux/vfs_dcache.h>' "$TARGET")
if [ "$INCLUDE_COUNT" -ne 1 ]; then
    echo "[ERROR] Expected 1 include directive, found $INCLUDE_COUNT"
    mv "${TARGET}.orig" "$TARGET"
    exit 1
fi

# Remove backup on success
rm -f "${TARGET}.orig"

echo "[SUCCESS] All NoMount statfs hooks injected successfully"
echo "[INFO] Injections:"
echo "  - Include: #include <linux/vfs_dcache.h>"
echo "  - Hook 1: user_statfs() - nomount_spoof_statfs(d_backing_inode(path.dentry), st)"
echo "  - Hook 2: fd_statfs() - nomount_spoof_statfs(d_backing_inode(f.file->f_path.dentry), st)"

exit 0
