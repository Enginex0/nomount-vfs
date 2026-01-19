#!/system/bin/sh
# NoMount Sync Script - Can be called by other modules to force sync
# Usage: sh /data/adb/modules/nomount/sync.sh [module_name]
# If module_name provided, sync only that module
# If no argument, sync all tracked modules
#
# This script is self-contained and does not depend on monitor.sh running.
# Safe to call multiple times - idempotent operation.
#
# Example usage from other modules (e.g., System App Nuker):
#   # After restoring an app, force NoMount to remove stale rules
#   sh /data/adb/modules/nomount/sync.sh system-app-nuker

NOMOUNT_DATA="/data/adb/nomount"
MODULES_DIR="/data/adb/modules"
TRACKING_DIR="$NOMOUNT_DATA/module_paths"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
TARGET_PARTITIONS="system vendor product system_ext odm oem mi_ext my_heytap prism optics oem_dlkm system_dlkm vendor_dlkm"

# Ensure data directory exists
mkdir -p "$NOMOUNT_DATA" 2>/dev/null
mkdir -p "$TRACKING_DIR" 2>/dev/null

# ============================================================
# LOGGING FUNCTIONS
# ============================================================
log_err() {
    echo "[$(date '+%H:%M:%S')] [SYNC] [ERROR] $*" >> "$LOG_FILE"
}

log_info() {
    echo "[$(date '+%H:%M:%S')] [SYNC] [INFO] $*" >> "$LOG_FILE"
}

log_debug() {
    echo "[$(date '+%H:%M:%S')] [SYNC] [DEBUG] $*" >> "$LOG_FILE"
}

# ============================================================
# FUNCTION: Find nm binary dynamically
# Checks multiple possible locations for flexibility
# ============================================================
find_nm_binary() {
    local possible_paths="
        /data/adb/modules/nomount/bin/nm
        /data/adb/modules/nomount/nm-arm64
        /data/adb/modules/nomount/nm
    "
    for path in $possible_paths; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ============================================================
# FUNCTION: Sync a single module's files
# Detects added/removed files and updates VFS rules accordingly
# ============================================================
sync_single_module() {
    local mod_name="$1"
    local mod_path="$MODULES_DIR/$mod_name"
    local tracking_file="$TRACKING_DIR/$mod_name"

    log_info "Syncing module: $mod_name"

    # Check if module directory exists
    if [ ! -d "$mod_path" ]; then
        log_info "Module directory does not exist: $mod_path"
        # Module was removed - clean up all its VFS rules
        if [ -f "$tracking_file" ]; then
            log_info "Removing all VFS rules for removed module: $mod_name"
            local removed=0
            local failed=0
            while IFS= read -r virtual_path; do
                [ -z "$virtual_path" ] && continue
                if "$LOADER" del "$virtual_path" < /dev/null 2>/dev/null; then
                    removed=$((removed + 1))
                    log_debug "Removed VFS rule: $virtual_path"
                else
                    failed=$((failed + 1))
                    log_err "Failed to remove VFS rule: $virtual_path"
                fi
            done < "$tracking_file"
            rm -f "$tracking_file"
            log_info "Cleaned up removed module $mod_name: $removed rules removed, $failed failed"
        fi
        return 0
    fi

    # Check if module is disabled or marked for removal
    if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ]; then
        log_info "Module is disabled or marked for removal: $mod_name"
        # Remove all VFS rules for disabled/removed module
        if [ -f "$tracking_file" ]; then
            local removed=0
            local failed=0
            while IFS= read -r virtual_path; do
                [ -z "$virtual_path" ] && continue
                if "$LOADER" del "$virtual_path" < /dev/null 2>/dev/null; then
                    removed=$((removed + 1))
                    log_debug "Removed VFS rule: $virtual_path"
                else
                    failed=$((failed + 1))
                    log_err "Failed to remove VFS rule: $virtual_path"
                fi
            done < "$tracking_file"
            rm -f "$tracking_file"
            log_info "Cleaned up disabled module $mod_name: $removed rules removed, $failed failed"
        fi
        return 0
    fi

    # If no tracking file exists, nothing to sync
    if [ ! -f "$tracking_file" ]; then
        log_debug "No tracking file for $mod_name, nothing to sync"
        return 0
    fi

    # Get current files in module
    local current_files="$NOMOUNT_DATA/.sync_tmp_$$"
    : > "$current_files"
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (cd "$mod_path" && find "$partition" -type f -o -type c 2>/dev/null) | \
                sed 's|^|/|' >> "$current_files"
        fi
    done

    local current_count=$(wc -l < "$current_files" 2>/dev/null || echo 0)
    local tracked_count=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    log_debug "Sync state for $mod_name: current=$current_count files, tracked=$tracked_count rules"

    # Find removed files (in tracking but not in current)
    local removed=0
    local remove_failed=0
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            # File was removed from module - remove VFS rule
            if "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null; then
                removed=$((removed + 1))
                log_info "Removed stale rule: $tracked_path"
            else
                remove_failed=$((remove_failed + 1))
                log_err "Failed to remove stale rule: $tracked_path"
            fi
        fi
    done < "$tracking_file"

    # Find added files (in current but not in tracking)
    local added=0
    local add_failed=0
    while IFS= read -r current_path; do
        [ -z "$current_path" ] && continue
        if ! grep -qxF "$current_path" "$tracking_file"; then
            # New file in module - register it
            local real_path="$mod_path$current_path"
            local add_result=false
            if [ -c "$real_path" ]; then
                # Whiteout - map to nonexistent to hide original
                if "$LOADER" add "$current_path" "/nonexistent" < /dev/null 2>/dev/null; then
                    add_result=true
                    log_info "Added new whiteout rule: $current_path"
                fi
            elif [ -f "$real_path" ]; then
                if "$LOADER" add "$current_path" "$real_path" < /dev/null 2>/dev/null; then
                    add_result=true
                    log_info "Added new file rule: $current_path -> $real_path"
                fi
            fi
            if [ "$add_result" = "true" ]; then
                added=$((added + 1))
            else
                add_failed=$((add_failed + 1))
                log_err "Failed to add rule for: $current_path"
            fi
        fi
    done < "$current_files"

    # Update tracking file if there were changes
    if [ "$removed" -gt 0 ] || [ "$added" -gt 0 ]; then
        cp "$current_files" "$tracking_file"
        log_info "Synced $mod_name: +$added -$removed (add_failed=$add_failed, remove_failed=$remove_failed)"
    else
        log_debug "No changes detected for $mod_name"
    fi

    rm -f "$current_files"
    return 0
}

# ============================================================
# FUNCTION: Sync all tracked modules
# ============================================================
sync_all_modules() {
    log_info "Syncing all tracked modules..."

    local synced=0
    local total=0

    # Iterate through all tracking files
    for tracking_file in "$TRACKING_DIR"/*; do
        [ ! -f "$tracking_file" ] && continue
        local mod_name=$(basename "$tracking_file")
        total=$((total + 1))
        sync_single_module "$mod_name"
        synced=$((synced + 1))
    done

    log_info "Sync complete: $synced/$total modules synced"
}

# ============================================================
# MAIN EXECUTION
# ============================================================
log_info "========== SYNC SCRIPT STARTED =========="
log_info "Arguments: $*"

# Find nm binary
LOADER=$(find_nm_binary)
if [ -z "$LOADER" ]; then
    log_err "nm binary not found! Cannot proceed."
    echo "ERROR: nm binary not found!" >&2
    exit 1
fi
log_debug "Using nm binary: $LOADER"

# Check if VFS driver is available
if [ ! -c "/dev/vfs_helper" ]; then
    log_err "/dev/vfs_helper not available - VFS driver not loaded"
    echo "ERROR: VFS driver not available" >&2
    exit 1
fi

# Process arguments
if [ -n "$1" ]; then
    # Sync specific module
    sync_single_module "$1"
else
    # Sync all modules
    sync_all_modules
fi

log_info "========== SYNC SCRIPT COMPLETED =========="
exit 0
