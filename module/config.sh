# NoMount Universal Hijacker Configuration
# Location: /data/adb/nomount/config.sh

# --- Hiding Mode ---
# 0 = Kernel-only (NoMount VFS + SUSFS, no Zygisk)
# 1 = Hybrid (Kernel + Zygisk maps/font hiding) [default]
hiding_mode=1

# --- Universal Hijacker Mode ---
# When enabled, NoMount will:
# 1. Detect existing overlay mounts and hijack them to VFS
# 2. Inject skip_mount into ALL modules for next boot
# 3. Monitor for new module installs and auto-hijack
# Default: true (enabled when /dev/vfs_helper exists)
universal_hijack=true

# --- Aggressive Mode ---
# When enabled, unmount overlays even if VFS registration partially fails
# When disabled, keep overlay as fallback if VFS fails (safer)
# Default: false (safer)
aggressive_mode=false

# --- Auto-inject skip_mount ---
# Automatically create skip_mount in all module directories
# This prevents KSU/Magisk from mounting modules on next boot
# Default: true
auto_skip_mount=true

# --- Monitor new modules ---
# Watch for newly installed modules and auto-hijack them
# Default: true
monitor_new_modules=true

# --- Excluded modules ---
# Comma-separated list of module IDs to NEVER hijack
# These modules will use normal overlay mounting
# Example: excluded_modules="zygisk_lsposed,shamiko"
excluded_modules=""

# --- Content-aware filtering ---
# Skip modules that modify /system/etc/hosts (DNS hijacking risk)
# Injecting hosts files can be detected and causes issues
# Default: true
skip_hosts_modules=true

# Support skip_nomount marker - modules can opt-out by creating this file
# Default: true
skip_nomount_marker=true

# EOF
