#!/bin/bash
# NoMount fs/proc/task_mmu.c hook injection script
# Injects maps filtering into show_map_vma() to hide specific paths from /proc/PID/maps
#
# This script merges functionality from:
# 1. NoMount's vfs_dcache_should_hide_map() check (CONFIG_FS_DCACHE_PREFETCH)
# 2. hide_stuff patch: lineage path spoofing and jit-zygote-cache hiding

set -e

TARGET="$1"
if [ ! -f "$TARGET" ]; then
    echo "ERROR: File not found: $TARGET"
    exit 1
fi

# Check if already patched
if grep -q "vfs_dcache_should_hide_map" "$TARGET"; then
    echo "INFO: task_mmu.c already has NoMount maps hooks"
    exit 0
fi

echo "Injecting NoMount maps filtering hooks into $TARGET..."

# Create backup
cp "$TARGET" "${TARGET}.backup"

# Add include after internal.h
if ! grep -q "linux/vfs_dcache.h" "$TARGET"; then
    sed -i '/#include "internal.h"/a\
#ifdef CONFIG_FS_DCACHE_PREFETCH\
#include <linux/vfs_dcache.h>\
#endif' "$TARGET"
    echo "  Added vfs_dcache.h include"
fi

# Use AWK to inject hooks into show_map_vma AFTER the struct inode declaration
# This avoids C90 "declaration after statement" errors
#
# Injected hooks:
# 1. NoMount: vfs_dcache_should_hide_map() - hides paths matching configured patterns
# 2. hide_stuff: lineage path spoofing - replaces "lineage" paths with framework-res.apk
# 3. hide_stuff: jit-zygote-cache hiding - completely hides these entries
awk '
BEGIN {
    in_func = 0
    brace_depth = 0
    injected = 0
    in_if_file = 0
    # Use variables for characters that need escaping
    SQ = sprintf("%c", 39)  # single quote
    NL = sprintf("%c", 10)  # newline (for C char literal)
    DASH = "-"
}

/^show_map_vma\(struct seq_file/ {
    in_func = 1
}

# Track brace depth when inside function
in_func == 1 && /\{/ {
    n = gsub(/\{/, "{")
    brace_depth += n
}

in_func == 1 && /\}/ {
    n = gsub(/\}/, "}")
    brace_depth -= n
    if (brace_depth <= 0) {
        in_func = 0
        brace_depth = 0
    }
}

# Detect entering if (file) block
in_func == 1 && /^[[:space:]]*if \(file\) \{/ && in_if_file == 0 {
    in_if_file = 1
}

# Find "struct inode *inode = file_inode" line and inject AFTER it
# This ensures we inject after ALL declarations in the block (C90 compliant)
in_func == 1 && in_if_file == 1 && /struct inode \*inode = file_inode/ && injected == 0 {
    print

    # ============================================================
    # BLOCK 1: NoMount path hiding (CONFIG_FS_DCACHE_PREFETCH)
    # Uses full path resolution for accurate matching
    # ============================================================
    print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
    print "\t\t{"
    print "\t\t\tchar *__nm_buf = (char *)__get_free_page(GFP_KERNEL);"
    print "\t\t\tif (__nm_buf) {"
    print "\t\t\t\tchar *__nm_path = file_path(file, __nm_buf, PAGE_SIZE);"
    print "\t\t\t\tif (!IS_ERR(__nm_path) && vfs_dcache_should_hide_map(__nm_path)) {"
    print "\t\t\t\t\tfree_page((unsigned long)__nm_buf);"
    print "\t\t\t\t\treturn;"
    print "\t\t\t\t}"
    print "\t\t\t\tfree_page((unsigned long)__nm_buf);"
    print "\t\t\t}"
    print "\t\t}"
    print "#endif"

    # ============================================================
    # BLOCK 2: hide_stuff - lineage path spoofing & jit-zygote-cache hiding
    # From 69_hide_stuff.patch - merged into AWK injection
    # - Lineage paths: spoof with /system/framework/framework-res.apk
    # - jit-zygote-cache: hide completely (return early)
    # ============================================================
    print "\t\t/* hide_stuff: lineage path spoofing and jit-zygote-cache hiding */"
    print "\t\t{"
    print "\t\t\tconst char *__hs_dname = file->f_path.dentry->d_name.name;"
    print "\t\t\t/* Spoof lineage paths with fake framework path */"
    print "\t\t\tif (strstr(__hs_dname, \"lineage\")) {"
    print "\t\t\t\tunsigned long long __hs_pgoff = ((loff_t)vma->vm_pgoff) << PAGE_SHIFT;"
    print "\t\t\t\tvm_flags_t __hs_flags = vma->vm_flags;"
    print "\t\t\t\tseq_setwidth(m, 25 + sizeof(void *) * 6 - 1);"
    printf "\t\t\t\tseq_printf(m, \"%%08lx-%%08lx %%c%%c%%c%%c %%08llx %%02x:%%02x %%lu \",\n"
    print "\t\t\t\t\tvma->vm_start, vma->vm_end,"
    printf "\t\t\t\t\t__hs_flags & VM_READ ? %sr%s : %s-%s,\n", SQ, SQ, SQ, SQ
    printf "\t\t\t\t\t__hs_flags & VM_WRITE ? %sw%s : %s-%s,\n", SQ, SQ, SQ, SQ
    printf "\t\t\t\t\t__hs_flags & VM_EXEC ? %sx%s : %s-%s,\n", SQ, SQ, SQ, SQ
    printf "\t\t\t\t\t__hs_flags & VM_MAYSHARE ? %ss%s : %sp%s,\n", SQ, SQ, SQ, SQ
    print "\t\t\t\t\t__hs_pgoff,"
    print "\t\t\t\t\tMAJOR(inode->i_sb->s_dev), MINOR(inode->i_sb->s_dev), inode->i_ino);"
    printf "\t\t\t\tseq_pad(m, %s %s);\n", SQ, SQ
    print "\t\t\t\tseq_puts(m, \"/system/framework/framework-res.apk\");"
    printf "\t\t\t\tseq_putc(m, %s\\n%s);\n", SQ, SQ
    print "\t\t\t\treturn;"
    print "\t\t\t}"
    print "\t\t\t/* Hide jit-zygote-cache entries completely */"
    print "\t\t\tif (strstr(__hs_dname, \"jit-zygote-cache\")) {"
    print "\t\t\t\treturn;"
    print "\t\t\t}"
    print "\t\t}"

    injected = 1
    next
}

{ print }

END {
    if (injected == 0) {
        print "WARNING: Hook not injected - struct inode line not found in show_map_vma" > "/dev/stderr"
    }
}
' "$TARGET" > "${TARGET}.new"

mv "${TARGET}.new" "$TARGET"

# Verify injection succeeded
hook_count=$(grep -c 'vfs_dcache_should_hide_map' "$TARGET" || true)
hide_stuff_count=$(grep -c '__hs_dname' "$TARGET" || true)
if [ "$hook_count" -ge 1 ] && [ "$hide_stuff_count" -ge 1 ]; then
    echo "  SUCCESS: maps filtering hooks injected (NoMount + hide_stuff)"
    rm -f "${TARGET}.backup"
else
    echo "  ERROR: Hook injection failed"
    echo "  Restoring backup..."
    mv "${TARGET}.backup" "$TARGET"
    exit 1
fi

echo "Done: maps filtering hooks injected into show_map_vma"
echo "  - NoMount vfs_dcache_should_hide_map() (CONFIG_FS_DCACHE_PREFETCH)"
echo "  - hide_stuff lineage path spoofing"
echo "  - hide_stuff jit-zygote-cache hiding"
