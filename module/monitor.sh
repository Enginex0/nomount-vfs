#!/bin/sh
# NoMount Universal Hijacker - monitor.sh
# Watches for module changes: new installs, disables, removes, and file changes
# Critical for proper restoration when debloat modules remove whiteouts

MODDIR=${0%/*}
PROP_FILE="$MODDIR/module.prop"
MODULES_DIR="/data/adb/modules"
NOMOUNT_DATA="/data/adb/nomount"
LOG_FILE="$NOMOUNT_DATA/nomount.log"
CONFIG_FILE="$NOMOUNT_DATA/config.sh"
LOADER="$MODDIR/bin/nm"
TARGET_PARTITIONS="system vendor product system_ext odm oem"

# Directory to track registered paths per module
TRACKING_DIR="$NOMOUNT_DATA/module_paths"
mkdir -p "$TRACKING_DIR"

MODULE_COUNT="$1"
HIJACKED_COUNT="$2"

[ -z "$MODULE_COUNT" ] && MODULE_COUNT=0
[ -z "$HIJACKED_COUNT" ] && HIJACKED_COUNT=0

# Load config
monitor_new_modules=true
excluded_modules=""
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

BASE_DESC="Universal Hijacker - VFS path redirection replaces all mounts"

# Build status string
update_status() {
    if [ "$MODULE_COUNT" -gt 0 ]; then
        if [ "$HIJACKED_COUNT" -gt 0 ]; then
            STATUS="[⚡VFS: $MODULE_COUNT modules | $HIJACKED_COUNT hijacked]\\n"
        else
            STATUS="[⚡VFS: $MODULE_COUNT modules active]\\n"
        fi
    else
        STATUS="[⚠️Idle: No modules found]\\n"
    fi
    sed -i "s|^description=.*|description=$STATUS$BASE_DESC|" "$PROP_FILE"
}

update_status

# ============================================================
# FUNCTION: Check if module is excluded
# ============================================================
is_excluded() {
    echo "$excluded_modules" | grep -qw "$1" && return 0
    return 1
}

# ============================================================
# FUNCTION: Unregister all VFS paths for a module
# Called when module is disabled/removed
# ============================================================
unregister_module() {
    local mod_name="$1"
    local tracking_file="$TRACKING_DIR/$mod_name"

    if [ ! -f "$tracking_file" ]; then
        echo "[MONITOR] No tracking file for $mod_name, nothing to unregister" >> "$LOG_FILE"
        return
    fi

    echo "[MONITOR] Unregistering module: $mod_name" >> "$LOG_FILE"

    local count=0
    while IFS= read -r virtual_path; do
        [ -z "$virtual_path" ] && continue
        "$LOADER" del "$virtual_path" < /dev/null 2>/dev/null && count=$((count + 1))
    done < "$tracking_file"

    echo "[MONITOR]   Removed $count VFS rules" >> "$LOG_FILE"
    rm -f "$tracking_file"

    # Remove skip_mount if we injected it
    local mod_path="$MODULES_DIR/$mod_name"
    if grep -q "^$mod_name$" "$NOMOUNT_DATA/skipped_modules" 2>/dev/null; then
        rm -f "$mod_path/skip_mount" 2>/dev/null
        sed -i "/^$mod_name$/d" "$NOMOUNT_DATA/skipped_modules"
        echo "[MONITOR]   Removed skip_mount" >> "$LOG_FILE"
    fi

    MODULE_COUNT=$((MODULE_COUNT - 1))
    [ "$MODULE_COUNT" -lt 0 ] && MODULE_COUNT=0
    update_status
}

# ============================================================
# FUNCTION: Register a module's files via VFS
# Tracks all registered paths for later cleanup
# ============================================================
register_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")
    local tracking_file="$TRACKING_DIR/$mod_name"

    echo "[MONITOR] Registering module: $mod_name" >> "$LOG_FILE"

    # Clear old tracking
    : > "$tracking_file"

    local count=0
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (
                cd "$mod_path" || exit
                find "$partition" -type f -o -type c 2>/dev/null | while read -r relative_path; do
                    real_path="$mod_path/$relative_path"
                    virtual_path="/$relative_path"

                    if [ -c "$real_path" ]; then
                        # Whiteout - map to nonexistent to hide original
                        "$LOADER" add "$virtual_path" "/nonexistent" < /dev/null 2>/dev/null
                    else
                        "$LOADER" add "$virtual_path" "$real_path" < /dev/null 2>/dev/null
                    fi

                    # Track this path
                    echo "$virtual_path" >> "$tracking_file"
                done
            )
        fi
    done

    count=$(wc -l < "$tracking_file" 2>/dev/null || echo 0)
    echo "[MONITOR]   Registered $count paths" >> "$LOG_FILE"
}

# ============================================================
# FUNCTION: Sync module files - detect added/removed files
# Critical for debloat modules that add/remove whiteouts
# ============================================================
sync_module_files() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")
    local tracking_file="$TRACKING_DIR/$mod_name"

    [ ! -f "$tracking_file" ] && return

    # Get current files in module
    local current_files=$(mktemp)
    for partition in $TARGET_PARTITIONS; do
        if [ -d "$mod_path/$partition" ]; then
            (cd "$mod_path" && find "$partition" -type f -o -type c 2>/dev/null) | \
                sed 's|^|/|' >> "$current_files"
        fi
    done

    # Find removed files (in tracking but not in current)
    local removed=0
    while IFS= read -r tracked_path; do
        [ -z "$tracked_path" ] && continue
        if ! grep -qxF "$tracked_path" "$current_files"; then
            # File was removed from module - remove from VFS
            "$LOADER" del "$tracked_path" < /dev/null 2>/dev/null && {
                removed=$((removed + 1))
                echo "[MONITOR] Removed stale rule: $tracked_path" >> "$LOG_FILE"
            }
        fi
    done < "$tracking_file"

    # Find added files (in current but not in tracking)
    local added=0
    while IFS= read -r current_path; do
        [ -z "$current_path" ] && continue
        if ! grep -qxF "$current_path" "$tracking_file"; then
            # New file in module - register it
            local real_path="$mod_path$current_path"
            if [ -c "$real_path" ]; then
                "$LOADER" add "$current_path" "/nonexistent" < /dev/null 2>/dev/null
            elif [ -f "$real_path" ]; then
                "$LOADER" add "$current_path" "$real_path" < /dev/null 2>/dev/null
            fi
            added=$((added + 1))
            echo "[MONITOR] Added new rule: $current_path" >> "$LOG_FILE"
        fi
    done < "$current_files"

    # Update tracking file
    if [ "$removed" -gt 0 ] || [ "$added" -gt 0 ]; then
        cp "$current_files" "$tracking_file"
        echo "[MONITOR] Synced $mod_name: +$added -$removed" >> "$LOG_FILE"
    fi

    rm -f "$current_files"
}

# ============================================================
# FUNCTION: Handle new module detection
# ============================================================
handle_new_module() {
    local mod_path="$1"
    local mod_name=$(basename "$mod_path")

    echo "[MONITOR] New module detected: $mod_name" >> "$LOG_FILE"

    if is_excluded "$mod_name"; then
        echo "[MONITOR] Skipping (excluded): $mod_name" >> "$LOG_FILE"
        return
    fi

    # Check if has mountable content
    local has_content=false
    for partition in $TARGET_PARTITIONS; do
        [ -d "$mod_path/$partition" ] && has_content=true && break
    done

    if [ "$has_content" = "true" ]; then
        # Inject skip_mount
        if [ ! -f "$mod_path/skip_mount" ]; then
            touch "$mod_path/skip_mount"
            echo "$mod_name" >> "$NOMOUNT_DATA/skipped_modules"
            echo "[MONITOR] Injected skip_mount: $mod_name" >> "$LOG_FILE"
        fi

        register_module "$mod_path"
        MODULE_COUNT=$((MODULE_COUNT + 1))
        update_status
    fi
}

# ============================================================
# FUNCTION: Main watch loop
# ============================================================
watch_modules() {
    echo "[MONITOR] Starting enhanced module watcher..." >> "$LOG_FILE"
    echo "[MONITOR] Watching for: new modules, disables, removes, file changes" >> "$LOG_FILE"

    # Build initial state
    local known_modules=""
    local known_disabled=""
    local known_removed=""

    for mod in $(ls -1 "$MODULES_DIR" 2>/dev/null); do
        [ "$mod" = "nomount" ] && continue
        known_modules="$known_modules $mod"
        [ -f "$MODULES_DIR/$mod/disable" ] && known_disabled="$known_disabled $mod"
        [ -f "$MODULES_DIR/$mod/remove" ] && known_removed="$known_removed $mod"
    done

    while true; do
        sleep 5  # Check every 5 seconds for responsiveness

        # Get current state
        local current_modules=""
        local current_disabled=""
        local current_removed=""

        for mod in $(ls -1 "$MODULES_DIR" 2>/dev/null); do
            [ "$mod" = "nomount" ] && continue
            current_modules="$current_modules $mod"
            [ -f "$MODULES_DIR/$mod/disable" ] && current_disabled="$current_disabled $mod"
            [ -f "$MODULES_DIR/$mod/remove" ] && current_removed="$current_removed $mod"
        done

        # Check for newly disabled modules
        for mod in $current_disabled; do
            if ! echo "$known_disabled" | grep -qw "$mod"; then
                echo "[MONITOR] Module disabled: $mod" >> "$LOG_FILE"
                unregister_module "$mod"
            fi
        done

        # Check for re-enabled modules (was disabled, now not)
        for mod in $known_disabled; do
            if ! echo "$current_disabled" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                if [ -d "$mod_path" ] && [ ! -f "$mod_path/remove" ]; then
                    echo "[MONITOR] Module re-enabled: $mod" >> "$LOG_FILE"
                    handle_new_module "$mod_path"
                fi
            fi
        done

        # Check for modules marked for removal
        for mod in $current_removed; do
            if ! echo "$known_removed" | grep -qw "$mod"; then
                echo "[MONITOR] Module marked for removal: $mod" >> "$LOG_FILE"
                unregister_module "$mod"
            fi
        done

        # Check for new modules
        for mod in $current_modules; do
            if ! echo "$known_modules" | grep -qw "$mod"; then
                local mod_path="$MODULES_DIR/$mod"
                if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                    handle_new_module "$mod_path"
                fi
            fi
        done

        # Check for removed modules (was in list, now gone)
        for mod in $known_modules; do
            if ! echo "$current_modules" | grep -qw "$mod"; then
                echo "[MONITOR] Module removed: $mod" >> "$LOG_FILE"
                unregister_module "$mod"
            fi
        done

        # Sync file changes for active modules (detect whiteout additions/removals)
        for mod in $current_modules; do
            local mod_path="$MODULES_DIR/$mod"
            if [ -d "$mod_path" ] && [ ! -f "$mod_path/disable" ] && [ ! -f "$mod_path/remove" ]; then
                if [ -f "$TRACKING_DIR/$mod" ]; then
                    sync_module_files "$mod_path"
                fi
            fi
        done

        # Update known state
        known_modules="$current_modules"
        known_disabled="$current_disabled"
        known_removed="$current_removed"
    done
}

# Start watching if enabled
if [ "$monitor_new_modules" = "true" ]; then
    watch_modules &
fi
