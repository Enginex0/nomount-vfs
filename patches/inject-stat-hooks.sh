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
# INJECTION 2: Syscall hook in SYSCALL_DEFINE4(newfstatat)
# This is the cleanest hook point - after VFS, before userspace copy
# NOTE: cp_new_stat appears multiple times - in newstat, newlstat, AND newfstatat
# We must only hook newfstatat which is SYSCALL_DEFINE4 (has dfd parameter)
# ============================================================================
inject_syscall_newfstatat_hook() {
    local marker="nomount_syscall_spoof_stat"

    if grep -q "$marker" "$TARGET"; then
        info "newfstatat syscall hook already injected, skipping."
        return 0
    fi

    # Check for SYSCALL_DEFINE4(newfstatat specifically
    if ! grep -q 'SYSCALL_DEFINE4(newfstatat' "$TARGET"; then
        warn "SYSCALL_DEFINE4(newfstatat) not found - may be different kernel version"
        return 0
    fi

    info "Injecting newfstatat syscall hook..."

    # Use awk with state tracking - look for SYSCALL_DEFINE4(newfstatat
    # then inject before the next cp_new_stat return in that function
    awk '
    /SYSCALL_DEFINE4\(newfstatat/ {
        in_newfstatat = 1
    }
    in_newfstatat && /return cp_new_stat\(&stat, statbuf\);/ {
        print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
        print "\tnomount_syscall_spoof_stat(dfd, filename, &stat);"
        print "#endif"
        print $0
        in_newfstatat = 0
        next
    }
    { print }
    ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"

    # Verify
    if ! grep -q "$marker" "$TARGET"; then
        error "Failed to inject newfstatat syscall hook"
    fi

    info "newfstatat syscall hook injected successfully."
}

# ============================================================================
# INJECTION 3: Compat syscall hook in COMPAT_SYSCALL_DEFINE4(newfstatat)
# 32-bit compatibility syscall
# NOTE: cp_compat_stat appears multiple times - in newstat, newlstat, AND newfstatat
# We must only hook newfstatat which uses vfs_fstatat (has dfd parameter)
# ============================================================================
inject_compat_syscall_newfstatat_hook() {
    local marker_count

    # Check if compat syscall hook already injected (we need TWO occurrences of the marker)
    marker_count=$(grep -c "nomount_syscall_spoof_stat" "$TARGET" 2>/dev/null || echo "0")
    if [[ "$marker_count" -ge 2 ]]; then
        info "compat newfstatat syscall hook already injected, skipping."
        return 0
    fi

    # Check for COMPAT_SYSCALL_DEFINE4(newfstatat specifically
    if ! grep -q 'COMPAT_SYSCALL_DEFINE4(newfstatat' "$TARGET"; then
        warn "COMPAT_SYSCALL_DEFINE4(newfstatat) not found - may be different kernel version"
        return 0
    fi

    info "Injecting compat newfstatat syscall hook..."

    # Use awk with state tracking - look for COMPAT_SYSCALL_DEFINE4(newfstatat
    # then inject before the next cp_compat_stat return in that function
    awk '
    /COMPAT_SYSCALL_DEFINE4\(newfstatat/ {
        in_compat_newfstatat = 1
    }
    in_compat_newfstatat && /return cp_compat_stat\(&stat, statbuf\);/ {
        print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
        print "\tnomount_syscall_spoof_stat(dfd, filename, &stat);"
        print "#endif"
        print $0
        in_compat_newfstatat = 0
        next
    }
    { print }
    ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"

    # Verify - should now have 2 occurrences
    marker_count=$(grep -c "nomount_syscall_spoof_stat" "$TARGET" 2>/dev/null || echo "0")
    if [[ "$marker_count" -lt 2 ]]; then
        warn "compat newfstatat hook may not have been injected correctly"
    else
        info "compat newfstatat syscall hook injected successfully."
    fi
}

# ============================================================================
# INJECTION 4: Syscall hook in SYSCALL_DEFINE4(fstatat64)
# Some kernels use fstatat64 instead of newfstatat for 64-bit stat
# ============================================================================
inject_syscall_fstatat64_hook() {
    # Anchor: return cp_new_stat64(&stat, statbuf);
    if ! grep -q 'return cp_new_stat64(&stat, statbuf);' "$TARGET"; then
        info "fstatat64 syscall not found (normal for some kernel versions), skipping."
        return 0
    fi

    # Check if already injected near cp_new_stat64
    if grep -B2 'return cp_new_stat64(&stat, statbuf);' "$TARGET" | grep -q "nomount_syscall_spoof_stat"; then
        info "fstatat64 syscall hook already injected, skipping."
        return 0
    fi

    info "Injecting fstatat64 syscall hook..."

    awk '
    /return cp_new_stat64\(&stat, statbuf\);/ && !done_fstatat64 {
        print "#ifdef CONFIG_FS_DCACHE_PREFETCH"
        print "\tnomount_syscall_spoof_stat(dfd, filename, &stat);"
        print "#endif"
        print $0
        done_fstatat64 = 1
        next
    }
    { print }
    ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"

    info "fstatat64 syscall hook injected successfully."
}

# ============================================================================
# Main execution
# ============================================================================
inject_include
inject_syscall_newfstatat_hook
inject_compat_syscall_newfstatat_hook
inject_syscall_fstatat64_hook

info "All NoMount stat hooks injected successfully into $TARGET"
exit 0
