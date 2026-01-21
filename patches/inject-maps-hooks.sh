#!/bin/bash
# inject-maps-hooks.sh - Injects NoMount maps hiding hooks into fs/proc/task_mmu.c
# Uses awk for clean multi-line injection with proper escaping

set -e

TARGET_FILE="${1:-fs/proc/task_mmu.c}"

if [ ! -f "$TARGET_FILE" ]; then
    echo "ERROR: Target file not found: $TARGET_FILE"
    exit 1
fi

# Check if already patched
if grep -q "vfs_dcache_should_hide_map" "$TARGET_FILE" 2>/dev/null; then
    echo "INFO: $TARGET_FILE already contains maps hooks, skipping"
    exit 0
fi

echo "Injecting maps hooks into $TARGET_FILE..."

# Create temp file
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Define the include injection
INCLUDE_INJECTION='#ifdef CONFIG_FS_DCACHE_PREFETCH
#include <linux/vfs_dcache.h>
#endif'

# Define the maps hook injection (using cat heredoc to preserve formatting)
MAPS_HOOK=$(cat << 'HOOKEOF'
#ifdef CONFIG_FS_DCACHE_PREFETCH
		{
			char *__nm_buf = (char *)__get_free_page(GFP_KERNEL);
			if (__nm_buf) {
				char *__nm_path = file_path(file, __nm_buf, PAGE_SIZE);
				if (!IS_ERR(__nm_path) && vfs_dcache_should_hide_map(__nm_path)) {
					free_page((unsigned long)__nm_buf);
					return;
				}
				free_page((unsigned long)__nm_buf);
			}
		}
#endif
		/* hide_stuff: lineage path spoofing and jit-zygote-cache hiding */
		{
			/* C90: all declarations must come before executable statements */
			struct inode *__hs_inode = file_inode(vma->vm_file);
			const char *__hs_dname = file->f_path.dentry->d_name.name;
			unsigned long long __hs_pgoff;
			vm_flags_t __hs_flags;
			/* Spoof lineage paths with fake framework path */
			if (strstr(__hs_dname, "lineage")) {
				__hs_pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;
				__hs_flags = vma->vm_flags;
				seq_setwidth(m, 25 + sizeof(void *) * 6 - 1);
				seq_printf(m, "%08lx-%08lx %c%c%c%c %08llx %02x:%02x %lu ",
					vma->vm_start, vma->vm_end,
					__hs_flags & VM_READ ? 'r' : '-',
					__hs_flags & VM_WRITE ? 'w' : '-',
					__hs_flags & VM_EXEC ? 'x' : '-',
					__hs_flags & VM_MAYSHARE ? 's' : 'p',
					__hs_pgoff,
					MAJOR(__hs_inode->i_sb->s_dev), MINOR(__hs_inode->i_sb->s_dev), __hs_inode->i_ino);
				seq_pad(m, ' ');
				seq_puts(m, "/system/framework/framework-res.apk");
				seq_putc(m, '\n');
				return;
			}
			/* Hide jit-zygote-cache entries completely */
			if (strstr(__hs_dname, "jit-zygote-cache")) {
				return;
			}
		}
HOOKEOF
)

# Injection 1: Add include after #include "internal.h"
# Using awk for clean multi-line insertion
awk -v include_inj="$INCLUDE_INJECTION" '
/#include "internal\.h"/ {
    print
    print include_inj
    next
}
{ print }
' "$TARGET_FILE" > "$TEMP_FILE"

mv "$TEMP_FILE" "$TARGET_FILE"

# Injection 2: Add maps hook after struct inode line in show_map_vma
# IMPORTANT: Track function context to only inject in show_map_vma, not other functions.
# SUSFS may also add code after the inode line, so we can't rely on next-line matching.
# Instead, we track when we enter show_map_vma and inject at the first inode line.
# Create a new temp file
TEMP_FILE=$(mktemp)

# Export MAPS_HOOK and use ENVIRON[] to avoid awk interpreting backslash escapes
# (e.g., '\n' in seq_putc(m, '\n') would become a literal newline with -v)
export MAPS_HOOK
awk '
BEGIN {
    in_show_map_vma = 0
    injected = 0
}
{
    # Detect entering show_map_vma function
    if (/^show_map_vma\(/ || /^static void$/ && prev_line ~ /^$/) {
        # Next line might be the function signature
    }
    if (/show_map_vma\(struct seq_file \*m,/) {
        in_show_map_vma = 1
    }

    # Detect leaving the function (next function definition or end of file section)
    if (in_show_map_vma && /^static / && !/show_map_vma/) {
        in_show_map_vma = 0
    }

    # If we are in show_map_vma and see the inode line, inject after it (only once)
    if (in_show_map_vma && !injected && /struct inode \*inode = file_inode\(vma->vm_file\);/) {
        print
        print ENVIRON["MAPS_HOOK"]
        injected = 1
        next
    }

    prev_line = $0
    print
}
' "$TARGET_FILE" > "$TEMP_FILE"

# Verify injection worked
if ! grep -q "vfs_dcache_should_hide_map" "$TEMP_FILE"; then
    echo "ERROR: Injection failed - vfs_dcache_should_hide_map not found in output"
    rm -f "$TEMP_FILE"
    exit 1
fi

if ! grep -q "jit-zygote-cache" "$TEMP_FILE"; then
    echo "ERROR: Injection failed - jit-zygote-cache not found in output"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Apply changes
mv "$TEMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "SUCCESS: Maps hooks injected into $TARGET_FILE"
