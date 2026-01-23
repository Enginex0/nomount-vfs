#!/bin/sh
# uninstall.sh - NoMount Universal Hijacker Cleanup
# Removes all traces when module is uninstalled
# This script runs BEFORE the module directory is deleted

MODDIR="${0%/*}"
LOADER="$MODDIR/bin/nm"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"

# Ensure PATH includes root framework binaries
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

log_cleanup() {
    echo "[UNINSTALL] $1"
}

# ============================================================
# PHASE 1: Clear VFS kernel state (if kernel driver available)
# ============================================================
if [ -c "/dev/vfs_helper" ] && [ -x "$LOADER" ]; then
    log_cleanup "Clearing VFS kernel state..."

    # Clear all registered file rules
    "$LOADER" clr 2>/dev/null && log_cleanup "  Cleared file rules"

    # Clear all hidden mounts
    "$LOADER" clrhide 2>/dev/null && log_cleanup "  Cleared hidden mounts"

    # Clear all maps patterns
    "$LOADER" clrmap 2>/dev/null && log_cleanup "  Cleared maps patterns"

    # Clear all blocked UIDs (unblock everyone)
    # Note: No bulk clear for UIDs, they'll reset on reboot anyway
    log_cleanup "  UID blocks will reset on reboot"
else
    log_cleanup "VFS driver not available - kernel state will reset on reboot"
fi

# ============================================================
# PHASE 2: Remove skip_mount files we injected into other modules
# ============================================================
log_cleanup "Removing skip_mount files from hijacked modules..."

# Check if we have a record of skipped modules
if [ -f "$NOMOUNT_DATA/skipped_modules" ]; then
    while IFS= read -r module_name; do
        [ -z "$module_name" ] && continue
        skip_file="$MODULES_DIR/$module_name/skip_mount"
        if [ -f "$skip_file" ]; then
            rm -f "$skip_file" 2>/dev/null && \
                log_cleanup "  Restored: $module_name (removed skip_mount)"
        fi
    done < "$NOMOUNT_DATA/skipped_modules"
else
    # Fallback: scan all modules for skip_mount files
    # Only remove if the module doesn't have its own legitimate skip_mount
    # We can't reliably distinguish, so we'll be conservative
    log_cleanup "  No skipped_modules record - modules will use overlay on next boot"

    # Fallback: If skipped_modules file was missing, scan for potential orphans
    log_cleanup "  Scanning for orphan skip_mount files..."
    # Only remove skip_mount if we have evidence NoMount created it
    # (corresponding tracking file exists in module_paths)
    if [ -d "$NOMOUNT_DATA/module_paths" ]; then
        for tracking_file in "$NOMOUNT_DATA/module_paths"/*; do
            [ -f "$tracking_file" ] || continue
            # Validate tracking file: must be regular file with valid content
            # Skip if it's a symlink (potential attack vector)
            [ -L "$tracking_file" ] && continue
            # Validate content: first line should be a path starting with /
            first_line=$(head -1 "$tracking_file" 2>/dev/null)
            case "$first_line" in
                /*) ;;  # Valid path format
                *) continue ;;  # Skip invalid/empty files
            esac
            mod_name="${tracking_file##*/}"
            # Additional validation: module name should be alphanumeric with limited special chars
            case "$mod_name" in
                *[!a-zA-Z0-9._-]*) continue ;;  # Skip if contains invalid chars
            esac
            skip_mount_file="/data/adb/modules/$mod_name/skip_mount"
            if [ -f "$skip_mount_file" ]; then
                rm -f "$skip_mount_file"
                log_cleanup "    Removed orphan: $skip_mount_file"
            fi
        done
    fi
fi

# ============================================================
# PHASE 3: Remove SUSFS entries we added (if SUSFS available)
# ============================================================
if command -v ksu_susfs >/dev/null 2>&1; then
    log_cleanup "Removing SUSFS entries..."

    # Remove device hiding
    ksu_susfs del_sus_path /dev/vfs_helper 2>/dev/null
    ksu_susfs del_sus_path /sys/class/misc/vfs_helper 2>/dev/null
    ksu_susfs del_sus_path /sys/devices/virtual/misc/vfs_helper 2>/dev/null

    log_cleanup "  Removed SUSFS path hiding entries"
fi

# Clean NoMount entries from SUSFS config files
log_cleanup "Cleaning SUSFS config entries..."
if [ -f "$MODDIR/susfs_integration.sh" ]; then
    # Source with required variables
    NOMOUNT_DATA="/data/adb/nomount"
    . "$MODDIR/susfs_integration.sh"
    if type susfs_clean_nomount_entries >/dev/null 2>&1; then
        if susfs_clean_nomount_entries; then
            log_cleanup "  SUSFS entries cleaned"
        else
            log_cleanup "  WARNING: SUSFS cleanup may have failed (some entries might remain)"
        fi
    else
        log_cleanup "  SUSFS cleanup function not available"
    fi
else
    log_cleanup "  susfs_integration.sh not found - skipping SUSFS cleanup"
fi

# ============================================================
# PHASE 4: Clean up NoMount data directory (including path tracking)
# ============================================================
log_cleanup "Removing NoMount data directory..."

# Remove module path tracking directory
if [ -d "$NOMOUNT_DATA/module_paths" ]; then
    rm -rf "$NOMOUNT_DATA/module_paths"
    log_cleanup "  Removed module path tracking"
fi

if [ -d "$NOMOUNT_DATA" ]; then
    # Log final state before deletion
    if [ -f "$NOMOUNT_DATA/nomount.log" ]; then
        log_cleanup "  Last log entries:"
        tail -5 "$NOMOUNT_DATA/nomount.log" 2>/dev/null | while read -r line; do
            log_cleanup "    $line"
        done
    fi

    rm -rf "$NOMOUNT_DATA"
    log_cleanup "  Removed: $NOMOUNT_DATA"
fi

# Remove legacy log location (from older versions)
[ -f "/data/adb/nomount.log" ] && rm -f "/data/adb/nomount.log"

# ============================================================
# PHASE 5: Clean up any stray files
# ============================================================
log_cleanup "Cleaning up stray files..."

# Remove any .nomount marker files we may have created
find "$MODULES_DIR" -name ".nomount_processed" -delete 2>/dev/null

# ============================================================
# COMPLETE
# ============================================================
log_cleanup "========================================"
log_cleanup "NoMount uninstallation complete."
log_cleanup "A REBOOT is recommended to fully restore"
log_cleanup "normal module overlay mounting behavior."
log_cleanup "========================================"

exit 0
